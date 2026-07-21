# Cljbang

A Clojure-like language that runs as Emacs Lisp.

> ⚠️ **WARNING**: I'm not sure if any of this is a good idea, but it kinda
> works for me.

Cljbang (`clj!`) compiles Clojure forms to Emacs Lisp forms and evaluates them in the
running Emacs. There is no subprocess, no transpiled text, and no runtime
beyond `cljbang-core.el` itself.

This project is heavily influenced by how I wrote [Squint](https://squint-cljs.github.io/squint/) and adopts its philosophy:

- Embrace the host and its data structures: interop should be first class without transforming between islands
- Light-weight: compilation happens at macro-expansion, so a byte-compiled file costs nothing at load. Uncompiled, about 70ms per 1000 defns.
- Performance first: compiled output should run fast, in the same ballpark as elisp

My previous attempt at a similar project to bring Clojure to Elisp involved a
transpiler. But I don't think using a transpiler in Emacs is user friendly for
writing quick functions and scripts.  Instead this project is a lite compiler
sitting in your elisp runtime and integrates tightly with it. You can just evaluate "Clojure" (in the cljbang dialect) as Elisp in a `.clj` buffer.


## Installation

Requires Emacs 28.1 or later.

```emacs-lisp
(use-package cljbang
  :vc (:url "https://github.com/borkdude/cljbang"))
```

Three files, so you can load only what you need:

| | |
|---|---|
| `cljbang-core.el` | the runtime compiled code calls. Depends on nothing else |
| `cljbang-string.el` | `clojure.string`, aliased to `str` |
| `cljbang.el` | the compiler, `clj!` and `cljbang-load-file` |
| `cljbang-mode.el` | inline evaluation, result overlays, completion |

A byte-compiled file that uses `clj!` needs only `cljbang-core` at load
time, because the macro is already expanded.

## Usage

You can use the `clj!` macro directly in side of en elisp buffer:

```emacs-lisp
(clj! (defn winner [{:keys [alice bob]}]
        (if (> alice bob) :alice :bob))

      (winner {:alice 3 :bob 5}))
;; => :bob
```

This defines a function straight into your elisp file.

Cljbang gives a better overall feeling when you move the source code to a `.clj` file and then load that file with:

```emacs-lisp
(cljbang-load-file "example.clj")
```

Then in your `example.clj` just put this line to enable `C-x C-e` to get inline evaluation working:

```clojure
;; -*- mode: clojure; cljbang-whole-buffer: t -*-
```

### Where the definitions go

`defn` and `def` intern real elisp symbols, so anything the file defines is
callable from elisp afterwards. Without an `ns` form the name is used as is:

```clojure
;; example.clj
(defn greet [x] (str "hi " x))
(def answer 42)
```

```emacs-lisp
(cljbang-load-file "example.clj")
(greet "you")   ;; => "hi you"
answer          ;; => 42
```

An `ns` form prefixes them instead, following the elisp convention: one
dash for the public API, two for what is internal to a package. `defn-`
gives you the second.

```clojure
;; my_config.clj
(ns my.config)
(defn greet [x] (str "hello " x))
(defn- shout [x] (upcase x))
(def answer 7)
```

```emacs-lisp
(cljbang-load-file "my_config.clj")
(my-config-greet "you")   ;; => "hello you"
my-config-answer          ;; => 7
(my-config--shout "hey")  ;; => "HEY"   internal, two dashes
```

Dots in the namespace become dashes, so `(ns my.deep.ns)` gives
`my-deep-ns-name`.

From cljbang code, reach them with the namespace:

```clojure
(my.config/greet "you")   ;; => "hello you"
```

The `ns` is in effect only while the file loads, so it does not leak into
whatever you evaluate next.

### Requiring

A `:require` loads what it names. Cljbang looks for a `.clj` file first,
relative to the requiring file and then along `cljbang-load-path`, and
falls back to loading an elisp feature of that name.

```clojure
;; lib/b.clj
(ns lib.b)
(defn hello [x] (str "hello from b: " x))
```

```clojure
;; app_a.clj
(ns app.a (:require [lib.b :as b]))
(defn run [] (b/hello "a"))     ;; => "hello from b: a"
```

Namespaces map to file names as in Clojure, so `lib.some-thing` is
`lib/some_thing.clj`.

Requiring an Emacs package loads it, and the alias saves you the prefix:

```clojure
(ns my.config (:require [magit :as m]))
(m/status)                       ;; calls magit-status
```

A require happens once, so cycles terminate. Use `:as-alias` to name a
namespace without loading it, as in Clojure.

Many Emacs built-ins have a prefix that names no feature, so aliasing one
is allowed as long as something is defined under it:

```clojure
(ns my.config (:require [string :as s]))
(s/trim "  hi  ")        ;; calls string-trim, nothing to load
```

A name that is neither a file, nor a feature, nor a prefix in use is a
typo, and cljbang says so rather than failing later at the call site.

Order matters, because a file is compiled and evaluated one form at a
time. The `ns` form runs its requires before anything below it, so a
dependency is loaded by the time the rest of the file is compiled. Within
a file, define before you use.

The same munging works in reverse, which is what makes ns-qualified syntax
the natural way to call an Emacs package:

```clojure
(magit/status)            ;; calls magit-status
(projectile/find-file)    ;; calls projectile-find-file
```

Internal names are not reachable this way on purpose. Use `el/` when you
really want one:

```clojure
(el/magit--display-buffer buf)
```

## Interop

Any name cljbang does not define compiles to a plain elisp call:

```clojure
(propertize "hi" 'face 'bold)
(make-overlay (point) (line-end-position))
```

`el/` reaches the host environment explicitly, the way `js/` does in
ClojureScript. Use it for names cljbang shadows, and for elisp names
containing a slash:

```clojure
(el/assoc "b" '(("a" . 1) ("b" . 2)))   ; elisp assoc, not Clojure's
el/tab-width                            ; a variable, not a function
(set! el/my/some-var 42)                ; slash preserved
```

## Supported

Special forms:

```
def defn defn- defmacro fn let set! if when cond do ns quote comment
-> ->> time with-out-str
```

Clojure calls only a handful of those special forms and defines the rest
as macros. Cljbang knows them all, for now.

### Macros

`defmacro` works. Build the expansion by hand, with `list` and `cons`:

```clojure
(defmacro twice [x] (list '+ x x))
(twice 3)                                  ;; => 6

(defmacro unless-neg [n body]
  (list 'if (list '< n 0) nil body))
(unless-neg 5 :ok)                         ;; => :ok
```

A macro is registered while compiling, so a form further down the same
file can use it. Expansion happens before the arguments are compiled,
which is the point of one. A `let` binding of the same name shadows it.

### Syntax quote is missing

⚠️ The gap that makes macros awkward. Cljbang reads Clojure with the
elisp reader, and the reader disagrees about every part of syntax quote:

| written | what actually happens |
|---|---|
| `` `(+ 1 2) `` | works, it is elisp's backquote |
| `` `(+ ,x 1) `` | **the unquote is silently dropped**, you get the symbol `x` |
| `~x` | reads as a symbol named `~x`, and does nothing |
| `~@xs` | likewise, a symbol |
| `x#` | reads as `x`, so an auto-gensym collides instead of being unique |

The second row is the dangerous one. Commas are whitespace in Clojure,
so cljbang strips them before the compiler runs, and that takes elisp's
`,` unquote with it. A backquote that looks like it interpolates quietly
does not:

```clojure
(let [x 5] `(+ ,x 1))     ;; => (+ x 1), not (+ 5 1)
```

Until this is fixed, build expansions with `list` and `cons`.

Functions:

```
+ - * / mod = not= < > <= >= inc dec not odd? even? zero?
first second rest nth count get contains? conj assoc
map filter reduce str pr-str println prn name subs
hash-map hash-set load-file
```

`clojure.string`, aliased to `str` out of the box, so `clj!` needs no
require for it:

```
join split replace upper-case lower-case capitalize trim blank?
```

```clojure
(str/join ", " ["a" "b"])   ;; => "a, b"
```

`str` is the only alias predefined. Any other alias comes from a
`:require`, which also means `clj!` cannot use one, having no ns form.

Map and set literals, destructuring (sequential and associative, nested,
in `let` and in fn params), and sets, maps, keywords and vectors called as
functions.

```clojure
(#{1 2 3} 1)                ;; => 1
(:a {:a 1})                 ;; => 1
(filter #{1 3} [1 2 3 4])   ;; => (1 3)
```

Anonymous function literals, with `%`, `%1`, `%2` and `%&`:

```clojure
(map #(+ % 1) [1 2 3])      ;; => (2 3 4)
(#(list %1 %&) 1 2 3)       ;; => (1 (2 3))
```

## Differences from Clojure

Host semantics win where they conflict, unless otherwise noted, like in Squint.

- `/` is elisp division: integers, no ratios
- characters are integers, so `(nth "abc" 0)` is `97`
- `assoc` copies the map, so it is O(n)
- `#{...}` and `#(...)` need source text and so do not work inside `clj!`.
  Use `hash-set` and `fn` there, or move your source to a `.clj` file.
- `:strs`, `:syms` and namespaced `:keys` are not implemented
- no syntax quote, so macros build their expansion with `list` and `cons`
- no protocols and no multimethods

## Benchmarks

Casual, one machine, Emacs 30.2, a namespace of 1000 `defn`s. Reproduce
with `bb bench-load` and `bb bench`.

Loading:

| | |
|---|---|
| `.clj` source, compiled on every load | 86 ms |
| byte-compiled `.el` using `clj!` | 2.0 ms |
| byte-compiled plain elisp | 1.0 ms |

Compilation happens at macro-expansion, so a byte-compiled file has no
cljbang left in it and loads at roughly the speed of the elisp it became.
Loading `.clj` source pays the compiler every time, which is the mode to
avoid if startup time matters.

Running, calling all 1000 functions once:

| | |
|---|---|
| cljbang | 0.40 ms |
| plain elisp | 0.36 ms |

Compiled output is plain elisp, so this is close to parity. Collection
code is further off, since `map` and `filter` dispatch through a wrapper
so a set or keyword can be used as a function, and `assoc` copies.

## Test

```
bb test
bb compile
```

## License

EPL-1.0
