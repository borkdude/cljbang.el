;;; demo-macro.el --- Clojure embedded in an elisp buffer via clj! -*- lexical-binding: t; -*-

;; The forms below are Clojure, sitting directly in an elisp file with
;; normal paren/vector/keyword highlighting.  They expand to elisp at
;; macro-expansion time, so byte-compiling this file byte-compiles the
;; Clojure too.

(add-to-list 'load-path
             (expand-file-name
              ".." (file-name-directory (or load-file-name buffer-file-name))))
(require 'cljbang)

(clj!
 (defn square [x] (* x x))

 (defn sum-squares [xs]
   (->> xs (map square) (reduce + 0)))

 (defn classify [n]
   (if (odd? n) :odd :even))

 (def lookup (hash-map :odd "odd!" :even "even!"))

 (defn describe [n]
       (str n " is " (get lookup (classify n)))))

;; elisp -> Clojure: defn makes a real elisp function, callable from
;; plain elisp.
(princ (format "elisp calls Clojure: (square 2) => %s\n" (square 2)))

(clj!
 (println "sum-squares:" (sum-squares [1 2 3 4]))
 (println (describe 7))
 (println (describe 8))
 (println "false is falsy:" (if false "no" "yes")))

;; Clojure -> elisp: unknown symbols compile to direct elisp calls, and
;; free symbols resolve against elisp's vars and functions, so all of
;; Emacs is just... there.
(clj!
 (println "elisp fn:" (upcase "shouting from clojure"))
 (println "elisp var:" (str "emacs " emacs-major-version "." emacs-minor-version))
 (println "elisp higher-order fn, clj lambda:"
          (mapcar (fn [x] (* x 10)) [1 2 3]))
 (println "threading through elisp fns:"
          (-> ["clojure" "loves" "emacs"]
              (append nil)
              (string-join " ")
              (capitalize)))

 (defn shout [& words]
   (upcase (string-join words " ")))
 (println "mixed defn:" (shout "it" "just" "works")))

;; Namespaced symbols: elisp symbols may contain `/', so str/join reads
;; as one symbol and the compiler routes it -- aliased Clojure vars get
;; Clojure semantics (note the arg order vs `string-join')...
(clj!
 (println "str/join:" (str/join ", " ["a" "b" "c"]))
 (println "str/upper-case:" (str/upper-case "qualified symbols"))
 (println "str/split:" (str/split "a,b,c" ","))
 (println "str/replace:" (str/replace "clojure on jvm" "jvm" "elisp"))
 (println "value position:" (map str/capitalize ["x" "y"])))

;; ...and unknown namespaces munge ns/name -> ns--name, so any elisp
;; package's double-dash functions are callable, Clojure-style.
(defun mylib-greet (name) (concat "Hello, " name "!"))
(clj! (println "munged interop:" (mylib/greet "borkdude")))
;; and the internal, two-dash form is reached through el/
(defun mylib--secret () "shh")
(clj! (println "internal name:" (el/mylib--secret)))

(clj!
 (defn foo [x y] (str x y))
 ;; eval inside clj! works with cljbang minor mode
 (foo "hello" "there")
 )

;; from emacs itself:
(foo "dude" "bar")

;; time, straight from clojure.core:
(clj!
 (with-out-str
  (println "timed result:"
           (time (reduce + 0 (map square [1 2 3 4 5 6 7 8 9 10]))))))

(let ((default-directory
       (file-name-directory (or load-file-name buffer-file-name))))
  (clj! (load-file "nsdemo.clj")))
