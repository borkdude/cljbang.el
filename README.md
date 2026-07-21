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

An example.

Wwhich buffers are visiting a file that is no longer there?

```clojure
(defn stale-buffers []
  (->> (el/buffer-list)
       (filter (fn [b] (let [f (el/buffer-file-name b)]
                         (and f (not (el/file-exists-p f))))))
       (map el/buffer-name)))
```

The same thing in Emacs Lisp, which is what it compiles to:

```emacs-lisp
(defun stale-buffers ()
  (let (result)
    (dolist (b (buffer-list) (nreverse result))
      (let ((f (buffer-file-name b)))
        (when (and f (not (file-exists-p f)))
          (push (buffer-name b) result))))))
```

This is running in the same process, without any subproceses, just a light-weight transform to Elisp and using some of the cljbang's standard library functions
The functions `buffer-list`, `buffer-file-name` and `file-exists-p` are the Emacs functions you already know, reached through `el/`.

## Installation

Requires Emacs 28.1 or later.

```emacs-lisp
(use-package cljbang
  :vc (:url "https://github.com/borkdude/cljbang"))
```

## Usage

You can use the `clj!` macro directly inside an elisp buffer:

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

or:

```emacs-lisp
(cljbang-require 'example)
```

The compiled result is cached beside the file as `example.clj.30-0.0.1.elc` and
reused until you edit the source, so this costs about what loading the
equivalent elisp would. The name carries the Emacs version and the cljbang
version, so upgrading either one rebuilds rather than loading output the current
compiler would not produce. The `.elc` files this produces, you can ignore in
version control.


Then in your `example.clj` just put this line to enable `C-x C-e` to get inline evaluation working:

```clojure
;; -*- mode: clojure; cljbang-whole-buffer: t -*-
```

### Interning

In Cljbang, `defn` and `def` intern real elisp symbols, so anything the file defines is
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

A file with no `ns` form can require at the top level, and elisp can too:

```clojure
(require '[lib.b :as b])
```

```emacs-lisp
(cljbang-require 'lib.b)
```

### Require

A `:require` loads either a cljbang `.clj` file or an elisp library, in that order.
Cljbang looks for a `.clj` file first, relative to the requiring file and then along `cljbang-load-path`, and
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
is allowed as long as something is defined under it. Here we load the built-in package `string`:

```clojure
(ns my.config (:require [string :as s]))
(s/trim "  hi  ")        ;; calls string-trim, nothing to load
```

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

There is no Clojure namespace called `el`, so clj-kondo reports every use
of it as unresolved. Tell it otherwise in your own `.clj-kondo/config.edn`:

```clojure
{:linters {:unresolved-namespace {:exclude [el]}}}
```

## Supported

Special forms:

```
def defn defn- defmacro fn let set! if when cond do ns require quote
comment -> ->> time with-out-str
```

Clojure calls only a handful of those special forms and defines the rest
as macros. Cljbang knows them all, for now.

### Macros

Since cljbang does not yet support syntax-quite you can build simple macros
using `list` and `cons`:

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


### Functions

```
+ - * / mod = not= < > <= >= inc dec not odd? even? zero?
first second rest nth count get contains? conj assoc
map filter reduce str pr-str println prn name subs
re-pattern re-find re-matches re-seq
hash-map hash-set load-file
```

`clojure.string`, aliased to `str` out of the box, so `clj!` needs no
require for it:

```
join split split-lines replace blank? includes? starts-with? ends-with?
index-of last-index-of upper-case lower-case capitalize reverse
trim triml trimr trim-newline
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

Regex literals, which are elisp regexps rather than Java ones, so groups
and alternation are spelled `\\(` and `\\|`:

```clojure
(re-find #"a+" "baaac")                    ;; => "aaa"
(re-seq #"a." "abac")                      ;; => ("ab" "ac")
(str/replace "a1b2" #"[0-9]" "#")          ;; => "a#b#"
(str/replace "a.b" "." "!")                ;; => "a!b", a string match is literal
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
- an empty list is false, because elisp has no empty list distinct from
  `nil`. `0`, `""`, `[]` and `{}` are all true as in Clojure, and `false`
  compiles to `nil`, but `(if '() :y :n)` is `:n` here and `:y` in
  Clojure
- `#{...}` and `#(...)` need source text and so do not work inside `clj!`.
  Use `hash-set` and `fn` there, or move your source to a `.clj` file.
- `:strs`, `:syms` and namespaced `:keys` are not implemented
- regexes use elisp syntax, not Java's, so `#"\\(a\\|b\\)"` where Clojure
  writes `#"(a|b)"`
- no syntax quote, so macros build their expansion with `list` and `cons`
- no protocols and no multimethods

## Benchmarks

Casual, one machine, Emacs 30.2, a namespace of 1000 `defn`s. Reproduce
with `bb bench-load` and `bb bench`.

Loading:

| | |
|---|---|
| `cljbang-load-file`, cold cache | 157 ms |
| `cljbang-load-file`, warm cache | 1.9 ms |
| byte-compiled `.el` using `clj!` | 2.0 ms |
| byte-compiled plain elisp | 1.0 ms |

Compilation happens at macro-expansion, so a byte-compiled file has no
cljbang left in it and loads at roughly the speed of the elisp it became.
`cljbang-load-file` gives a `.clj` file the same treatment, so neither
form of source is slower than the other once warm. Building the cache
costs about 160ms, paid once per edit rather than once per startup.

Running, calling all 1000 functions once:

| | |
|---|---|
| cljbang | 0.40 ms |
| plain elisp | 0.36 ms |

Compiled output is plain elisp, so this is close to parity. Collection
code is further off, since `map` and `filter` dispatch through a wrapper
so a set or keyword can be used as a function, and `assoc` copies.

In practice cljbang incurs little overhead. A byte-compiled file costs
about a millisecond more to load than the elisp it became, and runs
within about ten percent of it. For configuration code that is not
something you will notice.

## Test

```
bb test
bb compile
```

## License

MIT
