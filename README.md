# cljbang

A Clojure-like that runs as Emacs Lisp.

Cljbang (`clj!`) compiles Clojure forms to Emacs Lisp forms and evaluates them in the
running Emacs. There is no subprocess, no transpiled text, and no runtime
beyond `cljbang.el` itself.

This project is heavily influenced by how I wrote [squint](https://squint-cljs.github.io/squint/) and adopts its philosophy:

- Host and its data structures first: interop should be dead easy without transforming between islands
- Performance first

## Install

Requires Emacs 28.1 or later.

```emacs-lisp
(use-package cljbang
  :vc (:url "https://github.com/borkdude/cljbang"))
```

## Use

Clojure inside an elisp buffer, compiled at macro-expansion time:

```emacs-lisp
(clj! (defn winner [{:keys [alice bob]}]
        (if (> alice bob) :alice :bob))

      (winner {:alice 3 :bob 5}))
;; => :bob
```

A whole file:

```emacs-lisp
(cljbang-load-file "config.clj")
```

Form by form, with the result in an overlay. Bind `cljbang-eval-last-sexp`
in `cljbang-mode`, or put this on the first line of a `.clj` file:

```clojure
;; -*- mode: clojure; cljbang-whole-buffer: t -*-
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
def defn fn let set! if when cond do ns quote comment -> ->> time with-out-str
```

Functions:

```
+ - * / mod = not= < > <= >= inc dec not odd? even? zero?
first second rest nth count get contains? conj assoc
map filter reduce str println name subs
hash-map hash-set load-file
```

`clojure.string`, under any alias:

```
join split replace upper-case lower-case capitalize trim blank?
```

Anything not listed is an elisp call. That is the point, not a gap.

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

Host semantics win where they conflict, as in squint.

- `/` is elisp division: integers, no ratios
- characters are integers, so `(nth "abc" 0)` is `97`
- `assoc` copies the map, so it is O(n)
- `#{...}` and `#(...)` need source text and so do not work inside `clj!`.
  Use `hash-set` and `fn` there, or move your source to a `.clj` file.
- `:strs`, `:syms` and namespaced `:keys` are not implemented

## Test

```
make test
make compile
```

## License

EPL-1.0
