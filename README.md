# Cljbang

A Clojure-like language that runs as Emacs Lisp.

> ⚠️ **WARNING**: I'm not sure if any of this is a good idea, but it kinda
> works for me.

Cljbang (`clj!`) compiles Clojure forms to Emacs Lisp forms and evaluates them in the
running Emacs. There is no subprocess and no transpiled text.

Cljbang follows the same approach as [Squint](https://squint-cljs.github.io/squint/):

- Interop uses Emacs Lisp data structures directly.
- Functions defined in cljbang are callable from Emacs Lisp and vice versa.
- Compilation is fast, and byte-compiled files load about as fast as Emacs Lisp.
- Compiled code runs about as fast as Emacs Lisp.

![A .clj buffer in Emacs, evaluated inline](doc/screenshot.webp)

Example: which buffers are visiting a file that is no longer there?

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
  :vc (:url "https://github.com/borkdude/cljbang.el"))
```

From a clone, add the directory to `load-path` and require `cljbang-mode`
for inline evaluation:

```emacs-lisp
(add-to-list 'load-path "~/dev/cljbang.el")
(require 'cljbang-mode)
```

## Usage

You can use the `clj!` macro directly inside an elisp buffer:

```emacs-lisp
(clj! (defn winner [{:keys [alice bob]}]
        (if (> alice bob) :alice :bob))

      (winner {:alice 3 :bob 5}))
;; => :bob
```

This defines `winner` in the running Emacs.

For regular use, load a `.clj` file:

```emacs-lisp
(cljbang-load-file "~/.emacs.d/config.clj")
```

Or require a namespace:

```emacs-lisp
(cljbang-require 'example)
```

Loaded files are cached beside the source and reused until it changes. The
cache name carries the Emacs and cljbang versions, so upgrading either
rebuilds it. Ignore `*.clj.*.elc` in version control.

Add this file-local variable to a `.clj` file to enable inline evaluation
with `C-x C-e`:

```clojure
;; -*- mode: clojure; cljbang-whole-buffer: t -*-
```

### Interning

`defn` and `def` intern real elisp symbols for functions and variables. An
`ns` prefixes them using the elisp convention: one dash for public names
and two for `defn-`. Code without an `ns` uses `cljbang-user`, like
Clojure's `user`, so it cannot replace an unqualified elisp name such as
`car`. `clj!` is the exception: it interns names as written to define
elisp names directly.

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

From cljbang, reach them with the namespace. Dots become dashes, so
`(ns my.deep.ns)` gives `my-deep-ns-name`:

```clojure
(my.config/greet "you")   ;; => "hello you"
```

They are ordinary elisp functions. Arity is checked, `interactive` makes
a command, and `C-h f` shows the arglist and docstring.

Destructuring reads an alist, which is the shape Emacs passes around:

```clojure
(defn port [{:keys [host port]}] (str host ":" port))
```

```emacs-lisp
(port '((:host . "localhost") (:port . 8080)))   ;; => "localhost:8080"
```

Associative destructuring does not accept plists because they are
ambiguous with ordinary lists. A map that cljbang builds is a hash table,
so elisp reading one back uses `gethash`. A set is opaque to elisp, which
has no set type.


### Require

A `:require` first looks for a `.clj` file relative to the requiring file,
then on `cljbang-load-path`. If none exists, it loads an Emacs Lisp feature
with that name. `lib.some-thing` is `lib/some_thing.clj`.

```clojure
(ns my.config
  (:require [cljbang.core :refer [el! clj!]]
            [lib.b :as b]          ;; loads lib/b.clj
            [magit :as m]          ;; loads magit now, about 55ms
            [string :as s]         ;; a built-in prefix, nothing to load
            [org :as-alias o]))    ;; alias only, org loads when called

(b/hello "a")
(o/agenda)                       ;; org loads on this call, not before
(el/magit--display-buffer buf)   ;; internal names need el/
el/org-directory                 ;; void until org loads, variables do not autoload
```

```clojure
(require '[lib.b :as b])   ;; in a file with no ns form
```

```emacs-lisp
(cljbang-require 'lib.b)   ;; from elisp
```

A typo is caught when compiling, since an autoload counts as defined:

```
Warning (cljbang): magti/status resolves to magti-status, which is not defined
```

`cljbang-warn-unresolved` turns that off.

Munging is not reversible: `(ns a-b)` with `c` and `(ns a)` with `b-c`
both intern `a-b-c`. The second definition warns before replacing the
first:

```
Warning (cljbang): a/b-c interns a-b-c, already a-b/c
```

## Interop

`el/` reaches the host environment explicitly, the way `js/` does in
ClojureScript:

```clojure
(el/propertize "hi" 'face 'bold)
(el/make-overlay (el/point) (el/line-end-position))
(el/assoc "b" '(("a" . 1) ("b" . 2)))   ; elisp assoc, not Clojure's
el/tab-width                            ; a variable, not a function
(set! el/my/some-var 42)                ; slash preserved
```

A bare name cljbang does not define also compiles to a plain elisp
call, so `(propertize ...)` works as well. clj-kondo cannot know that,
so `el/` is the spelling the linter understands.

`el!` embeds elisp itself, for the macros whose arguments are not
expressions. `(clj! ...)` is the door back, compiled in place with the
surrounding scope, and a backquote inside is elisp's own, with `~` and
`~@` standing for `,` and `,@`:

```clojure
(el! (use-package magit
       :bind (("C-x g" . magit-status))))

(let [n 3]
  (el! (cl-loop repeat (clj! n) collect :x)))

(def todo-file "~/todo.org")
(el! (setq org-capture-templates
           `(("t" "Todo" entry (file ~(clj! todo-file)) "* TODO %?"))))
```

Reach for `el!` when an elisp macro demands it; cljbang's own forms
cover the rest. From elisp, `clj!` is the same door the other way, as
under Usage. There it sees no elisp locals, and unqualified names
resolve in `cljbang-user`.

## Standard library

Cljbang has these special forms:

```
def defn defn- defmacro fn let loop recur set! if do try ns require quote comment
```

Clojure treats only `def`, `if`, `do`, `set!`, `quote`, `try`, `loop` and
`recur` as special. The rest are macros there, and could become macros
here too.

### Macros

Build a macro with a syntax quote, unquoting with `~` and `~@`:

```clojure
(defmacro unless [test & body]
  `(if ~test nil (do ~@body)))
(unless false :ok)                         ;; => :ok
```

A syntax quote resolves unqualified names in the macro's namespace,
including vars defined later. Use `el/` for Emacs Lisp names:

```clojure
(ns my.config)
(defmacro shout [x] `(el/upcase (greet ~x)))   ;; greet is my-config-greet
(defn greet [x] (str "hello " x))              ;; defined after the macro
```

Each name ending in `#` gets one fresh symbol per template, so a binding
the macro introduces cannot capture one at the call site:

```clojure
(defmacro my-or [a b]
  `(let [v# ~a] (if v# v# ~b)))
(let [v 5] (my-or nil v))                  ;; => 5
```

A `#(...)` in a template is an error, since its `%` would be qualified
like any other name. Write `(fn [x#] ...)`. Building an expansion with
`list` and `cons` still works.

These ship as macros rather than compiler support:

```
when cond case if-let when-let doseq dotimes -> ->> some-> some->>
with-out-str time
```

### Functions

Supported functions:

```
+ - * / mod = not= < > <= >= inc dec not odd? even? zero? pos? neg?
first second rest last nth count get contains? conj assoc seq vec set
map filter remove reduce concat sort sort-by str pr-str println prn name subs
mapv mapcat into range take drop take-while drop-while distinct
some every? empty? apply partial comp complement constantly
keys vals merge dissoc select-keys update get-in assoc-in update-in
re-pattern re-find re-matches re-seq
hash-map hash-set throw ex-info ex-message ex-data ex-cause
slurp spit load-file
atom deref reset! swap!
keyword symbol nil? some? map? set? vector? fn? symbol? keyword?
string? number? integer? int?
```

An atom derefs with `@` as well as `deref`:

```clojure
(let [a (atom 0)] (swap! a inc) @a)   ;; => 1
```

`clojure.edn/read-string` is available as `edn/read-string` without a
`require`. `false` reads as nil, and char and tagged literals are not
supported.

`clojure.string` is available as `str` without a `require`:

```
join split split-lines replace blank? includes? starts-with? ends-with?
index-of last-index-of upper-case lower-case capitalize reverse
trim triml trimr trim-newline
```

```clojure
(str/join ", " ["a" "b"])   ;; => "a, b"
```

`str` is the only predefined alias. Any other comes from a `:require`,
which `clj!` can carry too:

```emacs-lisp
(clj! (ns my.config (:require [magit :as m]))
      (m/status))
```

Cljbang supports map and set literals and nested sequential and associative
destructuring in `let` bindings and function parameters. Sets, maps,
keywords and vectors can be called as functions.

```clojure
(#{1 2 3} 1)                ;; => 1
(:a {:a 1})                 ;; => 1
(filter #{1 3} [1 2 3 4])   ;; => (1 3)
```

Regex literals pass through to the host engine, as they do in Clojure,
where `#"(a|b)"` is Java's syntax rather than Clojure's. Here the engine
is Emacs's, so groups and alternation are spelled `\(` and `\|`. A
backslash stands for itself:

```clojure
(re-find #"a+" "baaac")                    ;; => "aaa"
(re-seq #"a." "abac")                      ;; => ("ab" "ac")
(re-find #"\(a\|b\)" "xbx")               ;; => ["b" "b"], a group and an
                                           ;;    alternation
(str/replace "a1b2" #"[0-9]" "#")          ;; => "a#b#"
(str/replace "a.b" "." "!")                ;; => "a!b", a string match is literal
```

Anonymous function literals, with `%`, `%1`, `%2` and `%&`:

```clojure
(map #(+ % 1) [1 2 3])      ;; => (2 3 4)
(#(list %1 %&) 1 2 3)       ;; => (1 (2 3))
```

## Differences from Clojure

When Clojure and Emacs Lisp semantics differ, cljbang usually uses Emacs
Lisp semantics:

```clojure
(/ 1 2)             ;; => 0, elisp division, no ratios
(nth "abc" 0)       ;; => 97, characters are integers
(if (list) :y :n)   ;; => :n, elisp has no empty list distinct from nil
(if [] :y :n)       ;; => :y, and 0, "" and {} are true as in Clojure

#"\(a\|b\)"         ;; the host engine's syntax, as Clojure's #"(a|b)" is Java's
(assoc m :k 1)      ;; copies the map, so O(n)

(try (f) (catch :default e e))         ;; catches anything like CLJS
(try (f) (catch el/file-missing e e))  ;; or a host error symbol, like js/Error

(get '((:a . 1)) :a)   ;; => 1, an alist reads as a map
(get '((1 2) (3 4)) 1) ;; => (2), and so does a list of lists. Clojure
                       ;;    finds nothing here, but elisp uses lists for
                       ;;    both sequences and maps
```

These reader forms need source rewriting and do not work inside `clj!`:
`#{}`, `#()`, `#""`, `#_`, `` ` ``, `~`, `~@` and `@`. Use `hash-set`, `fn`,
`re-pattern`, `list` and `deref`, or move the code to a `.clj` file:

```clojure
(clj! #{1 2})       ;; read error
(clj! (hash-set 1 2))
```

Not implemented:

- `:strs`, `:syms` and namespaced `:keys` destructuring.
- The `:while` modifier in `doseq`.
- Protocols and multimethods.

## Shipping a package

Emacs's `load-path` does not apply to `.clj` files, so an installed
package must register its directory:

```emacs-lisp
;;; myproject.el --- Example cljbang package -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "28.1") (cljbang "0.0.4"))

(require 'cljbang)
(add-to-list 'cljbang-load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(cljbang-require 'myproject.commands)
(provide 'myproject)
```

Include `myproject/commands.clj` in the package, and name the namespace
after the package, since what it defines is interned under that prefix.
A `greet` there is `myproject-commands-greet`, an ordinary Emacs Lisp
call after requiring `myproject`.

Do not include `*.clj.*.elc` files. They are generated caches, not
package files.

## Clj-kondo

Cljbang ships a clj-kondo configuration. Add the repo to a `deps.edn`
and import it:

```clojure
{:deps {io.github.borkdude/cljbang.el {:git/tag "..." :git/sha "..."}}}
```

```
mkdir -p .clj-kondo
clj-kondo --lint "$(clojure -Spath)" --copy-configs --skip-lint
```

Without a JVM, `:config-paths` in `.clj-kondo/config.edn` pointing at a
checkout works too:
`["/path/to/cljbang/resources/clj-kondo.exports/borkdude/cljbang"]`.

Require `cljbang.core` with `:refer`, so `el!` and `clj!` resolve:

```clojure
(ns my.config
  (:require [cljbang.core :refer [el! clj!]]))
```

The require loads nothing, since cljbang implements that namespace
itself.

Inside `el!` only the `(clj! ...)` parts are linted as Clojure. The
elisp around them is invisible, so a binding used by bare elisp alone
reads as unused, where `(clj! n)` counts as a use. A backquote inside
`el!` is elisp's own and is left alone, and a `~` outside one is
reported with the compiler's message.

## Benchmarks

This is a casual benchmark done on my local machine with Emacs 30.2 and 1000 `defn`s. You can reproduce it with `bb bench-load`
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
about a millisecond at load and ten percent at run time. Collection
operations are slower because `map` and `filter` dispatch through a wrapper
and `assoc` copies maps.

## Test

```
bb test
bb compile
```

## License

MIT
