# cljbang

A Clojure-like that runs as Emacs Lisp.

Cljbang (`clj!`) compiles Clojure forms to Emacs Lisp forms and evaluates them in the
running Emacs. There is no subprocess, no transpiled text, and no runtime
beyond `cljbang.el` itself.

This project is heavily influenced by how I wrote [squint](https://squint-cljs.github.io/squint/) and adopts its philosophy to writing a Clojure-like:

- Host and its data structures are embraced: interop should be dead easy without transforming between islands
- Light-weight: the compiler step should be fast such that using cljbang doesn't incur a lot of overhead compared to using elisp directly.
- Performance first: compiled output should run fast, in the same ballpark as elisp

## Install

Requires Emacs 28.1 or later.

```emacs-lisp
(use-package cljbang
  :vc (:url "https://github.com/borkdude/cljbang"))
```

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

An `ns` form prefixes them instead. Dots become dashes, then `--` joins the
name, which is the usual elisp convention for a package-private symbol:

```clojure
;; my_config.clj
(ns my.config)
(defn greet [x] (str "hello " x))
(def answer 7)
```

```emacs-lisp
(cljbang-load-file "my_config.clj")
(my-config--greet "you")   ;; => "hello you"
my-config--answer          ;; => 7
```

From Clojure, reach them with the namespace:

```clojure
(my.config/greet "you")   ;; => "hello you"
```

The `ns` is in effect only while the file loads, so it does not leak into
whatever you evaluate next.

The same munging works in reverse, which is how interop with elisp packages
that use `--` reads naturally:

```clojure
(mylib/frob x)   ;; calls the elisp function mylib--frob
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
