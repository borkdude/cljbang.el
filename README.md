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

Which buffers are visiting a file that is no longer there?

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

`buffer-list`, `buffer-file-name` and `file-exists-p` are the Emacs
functions you already know, reached through `el/`.

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

The result is cached beside the file as `example.clj.30-0.0.1.elc` and
reused until you edit the source, so this costs about what loading the
equivalent elisp would. The name carries the Emacs and cljbang versions,
so upgrading either rebuilds. Ignore `*.clj.*.elc` in version control.

Then in your `example.clj` just put this line to enable `C-x C-e` to get inline evaluation working:

```clojure
;; -*- mode: clojure; cljbang-whole-buffer: t -*-
```

### Interning

`defn` and `def` intern real elisp symbols, so anything a file defines is
callable from elisp afterwards. Without an `ns` the name is used as is.
An `ns` prefixes it, following the elisp convention: one dash for the
public API, two for internal, which is what `defn-` gives you.

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
(my-config--shout "hey")  ;; => "HEY"
```

Dots become dashes, so `(ns my.deep.ns)` gives `my-deep-ns-name`. From
cljbang, reach them with the namespace: `(my.config/greet "you")`.

The `ns` is in effect only while the file loads, so it does not leak into
whatever you evaluate next.

### Require

A `:require` loads a `.clj` file if it finds one, relative to the
requiring file and then along `cljbang-load-path`, and otherwise loads an
elisp feature of that name. Namespaces map to file names as in Clojure,
so `lib.some-thing` is `lib/some_thing.clj`.

```clojure
(ns app.a (:require [lib.b :as b]))
(defn run [] (b/hello "a"))
```

A file with no `ns` can require at the top level, and so can elisp:

```clojure
(require '[lib.b :as b])
```

```emacs-lisp
(cljbang-require 'lib.b)
```

A require happens once, so cycles terminate. `:as-alias` names a
namespace without loading it, as in Clojure. Aliasing a prefix that names
no feature is allowed when something is defined under it, which covers
Emacs built-ins like `string-`.

Qualified names reach elisp the same way, which is what makes this the
natural way to call a package. Internal names are not reachable so use
`el/` for those:

```clojure
(magit/status)                  ;; calls magit-status
(el/magit--display-buffer buf)  ;; the internal one
```

### Calling a package

`(magit/status)` works with no require, because `magit-status` is an
autoload and calling it pulls magit in. Requiring the package up front
would give that up.

clj-kondo does not know that. Either require the package, which is the
only thing that satisfies it on its own but loads magit when the file
loads, or stay bare and add the packages you call to the same exclude
list as `el`, below.

Going bare means a typo like `(magti/status)` fails when it is called
rather than at load.

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

Cljbang has no syntax quote yet, so build macros
using `list` and `cons`:

```clojure
(defmacro twice [x] (list '+ x x))
(twice 3)                                  ;; => 6

(defmacro unless-neg [n body]
  (list 'if (list '< n 0) nil body))
(unless-neg 5 :ok)                         ;; => :ok
```

A macro is registered while compiling, so a form further down the same
file can use it. A `let` binding of the same name shadows it.


### Functions

Supported functions:

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

Emacs 30.2, one machine, 1000 `defn`s. Reproduce with `bb bench-load`
and `bb bench`.

| loading | |
|---|---|
| `cljbang-load-file`, cold cache | 157 ms |
| `cljbang-load-file`, warm cache | 1.9 ms |
| byte-compiled plain elisp | 1.0 ms |

| calling all 1000 | |
|---|---|
| cljbang | 0.40 ms |
| plain elisp | 0.36 ms |

Compiled output is plain elisp, so once the cache is warm the overhead is
about a millisecond at load and ten percent at run time. Collection code
is further off, since `map` and `filter` dispatch through a wrapper and
`assoc` copies.

## Test

```
bb test
bb compile
```

## License

MIT
