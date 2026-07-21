;;; cljbang-test.el --- Tests for cljbang -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cljbang)

(defun cljbang-test--eval (src)
  "Evaluate Clojure SRC and return the value of the last form."
  (cljbang-eval-string src))


;;; Map literals

(ert-deftest cljbang-test-map-empty ()
  (should (= 0 (cljbang-test--eval "(count {})"))))

(ert-deftest cljbang-test-map-lookup ()
  (should (= 1 (cljbang-test--eval "(get {:a 1} :a)")))
  (should (equal "x" (cljbang-test--eval "(get {:a \"x\"} :a)")))
  (should (null (cljbang-test--eval "(get {:a 1} :missing)"))))

(ert-deftest cljbang-test-map-spaced-braces ()
  (should (= 1 (cljbang-test--eval "(get { :a 1 } :a)"))))

(ert-deftest cljbang-test-map-commas ()
  "Commas read as unquote and are spliced back out."
  (should (= 2 (cljbang-test--eval "(count {:a 1, :b 2})"))))

(ert-deftest cljbang-test-map-nested ()
  (should (= 2 (cljbang-test--eval "(get (get {:a {:b 2}} :a) :b)"))))

(ert-deftest cljbang-test-map-in-vector ()
  (should (= 1 (cljbang-test--eval "(get (nth [{:a 1}] 0) :a)"))))

(ert-deftest cljbang-test-map-from-fn-body ()
  (should (= 3 (cljbang-test--eval "(get ((fn [n] {:x n}) 3) :x)"))))

(ert-deftest cljbang-test-map-unbalanced-braces-error ()
  (should-error (cljbang-test--eval "{:a 1"))
  (should-error (cljbang-test--eval "(list :a 1})")))

(ert-deftest cljbang-test-dotted-pairs-survive ()
  "Quoted elisp alists must not be mangled by brace splicing."
  (should (equal '((".*" . "/tmp")) (cljbang-test--eval "'((\".*\" . \"/tmp\"))")))
  (should (equal '(("a" . 1)) (cljbang-test--eval "(get {:al '((\"a\" . 1))} :al)"))))


;;; Set literals

(ert-deftest cljbang-test-set-empty ()
  (should (= 0 (cljbang-test--eval "(count #{})"))))

(ert-deftest cljbang-test-set-count-and-dedup ()
  (should (= 3 (cljbang-test--eval "(count #{1 2 3})")))
  (should (= 2 (cljbang-test--eval "(count #{1 1 2})"))))

(ert-deftest cljbang-test-set-contains ()
  (should (cljbang-test--eval "(contains? #{1 2} 2)"))
  (should-not (cljbang-test--eval "(contains? #{1 2} 9)")))

(ert-deftest cljbang-test-set-get-returns-element ()
  (should (= 2 (cljbang-test--eval "(get #{1 2} 2)"))))

(ert-deftest cljbang-test-set-conj ()
  (should (= 3 (cljbang-test--eval "(count (conj #{1 2} 3))")))
  (should (= 2 (cljbang-test--eval "(count (conj #{1 2} 2))"))))

(ert-deftest cljbang-test-set-nested-in-map ()
  (should (= 2 (cljbang-test--eval "(count (get {:tags #{:a :b}} :tags))"))))

(ert-deftest cljbang-test-set-rewrite-skips-strings ()
  "A #{ inside a string literal must be left alone."
  (should (equal "#{not a set}" (cljbang-test--eval "(str \"#{not a set}\")")))
  (should (cljbang-test--eval "(contains? #{\"#{x}\"} \"#{x}\")")))

(ert-deftest cljbang-test-hash-set-fn ()
  (should (= 3 (cljbang-test--eval "(count (hash-set 1 2 3))"))))


;;; #(...) anonymous functions

(ert-deftest cljbang-test-fn-literal-percent ()
  (should (equal '(2 3 4) (cljbang-test--eval "(map #(+ % 1) [1 2 3])")))
  (should (equal '(2 4) (cljbang-test--eval "(map #(* %1 2) [1 2])"))))

(ert-deftest cljbang-test-fn-literal-positional ()
  (should (= 7 (cljbang-test--eval "(#(+ %1 %2) 3 4)"))))

(ert-deftest cljbang-test-fn-literal-rest ()
  (should (equal '(1 (2 3)) (cljbang-test--eval "(#(list %1 %&) 1 2 3)"))))

(ert-deftest cljbang-test-fn-literal-no-args ()
  (should (null (cljbang-test--eval "(#(list))"))))

(ert-deftest cljbang-test-fn-literal-nests-other-forms ()
  (should (equal '(3 4) (cljbang-test--eval "(map #(-> % inc inc) [1 2])")))
  (should (equal '(1 2) (cljbang-test--eval "(map #(get % :a) [{:a 1} {:a 2}])")))
  (should (equal '(2 1) (cljbang-test--eval "(map #(count #{% 9}) [1 9])"))))

(ert-deftest cljbang-test-fn-literal-rewrite-skips-strings ()
  (should (equal "#(not a fn)" (cljbang-test--eval "(#(str \"#(not a fn)\"))"))))


;;; Destructuring

(ert-deftest cljbang-test-destructure-sequential ()
  (should (= 3 (cljbang-test--eval "(let [[a b] [1 2]] (+ a b))")))
  (should (= 6 (cljbang-test--eval "(let [[a [b c]] [1 [2 3]]] (+ a b c))"))))

(ert-deftest cljbang-test-destructure-rest ()
  (should (equal '(2 3) (cljbang-test--eval "(let [[a & r] [1 2 3]] r)"))))

(ert-deftest cljbang-test-destructure-as ()
  (should (equal [1 2] (cljbang-test--eval "(let [[a :as all] [1 2]] all)")))
  (should (equal '(1 (2 3) [1 2 3])
                 (cljbang-test--eval "(let [[a & r :as all] [1 2 3]] (list a r all))"))))

(ert-deftest cljbang-test-destructure-over-length ()
  "Missing positions are nil, as in Clojure."
  (should (equal '(1 nil nil) (cljbang-test--eval "(let [[a b c] [1]] (list a b c))"))))

(ert-deftest cljbang-test-destructure-keys ()
  (should (= 3 (cljbang-test--eval "(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))"))))

(ert-deftest cljbang-test-destructure-explicit-pair ()
  (should (= 5 (cljbang-test--eval "(let [{a :a} {:a 5}] a)"))))

(ert-deftest cljbang-test-destructure-or-default ()
  (should (equal '(1 9) (cljbang-test--eval "(let [{:keys [a b] :or {b 9}} {:a 1}] (list a b))"))))

(ert-deftest cljbang-test-destructure-map-as ()
  (should (= 1 (cljbang-test--eval "(let [{:keys [a] :as m} {:a 1}] (get m :a))"))))

(ert-deftest cljbang-test-destructure-mixed-nesting ()
  (should (= 7 (cljbang-test--eval "(let [[{:keys [a]}] [{:a 7}]] a)")))
  (should (= 7 (cljbang-test--eval "(let [{[x y] :pt} {:pt [3 4]}] (+ x y))"))))

(ert-deftest cljbang-test-destructure-in-fn-params ()
  (should (= 3 (cljbang-test--eval "((fn [[a b]] (+ a b)) [1 2])")))
  (should (= 9 (cljbang-test--eval "((fn [{:keys [a]}] a) {:a 9})")))
  (should (equal '(1 2 3) (cljbang-test--eval "((fn [a & [b c]] (list a b c)) 1 2 3)"))))

(ert-deftest cljbang-test-destructure-shadowing ()
  (should (= 2 (cljbang-test--eval "(let [a 1 [a] [2]] a)"))))


;;; el/ host environment

(ert-deftest cljbang-test-el-function-call ()
  (should (equal "AB" (cljbang-test--eval "(el/upcase \"ab\")"))))

(ert-deftest cljbang-test-el-variable-value ()
  "el/ resolves a variable, not only a function."
  (should (integerp (cljbang-test--eval "el/tab-width"))))

(ert-deftest cljbang-test-el-unshadows-elisp-builtins ()
  "Clojure's get and assoc shadow elisp's; el/ reaches the originals."
  (should (equal '("b" . 2)
                 (cljbang-test--eval "(el/assoc \"b\" '((\"a\" . 1) (\"b\" . 2)))"))))

(ert-deftest cljbang-test-el-keeps-slashes ()
  "el/ takes the rest of the name verbatim, so my/foo is not munged."
  (should (eq 'my/some-var (cljbang--el-symbol 'el/my/some-var))))

(ert-deftest cljbang-test-multi-slash-is-an-error ()
  (should-error (cljbang-test--eval "(a/b/c)")))


;;; set!

(ert-deftest cljbang-test-set-bang-local ()
  (should (= 5 (cljbang-test--eval "(let [x 1] (set! x 5) x)"))))

(ert-deftest cljbang-test-set-bang-global ()
  (defvar cljbang-test--global nil)
  (setq cljbang-test--global nil)
  (cljbang-test--eval "(set! cljbang-test--global 7)")
  (should (= 7 cljbang-test--global)))

(ert-deftest cljbang-test-set-bang-requires-symbol ()
  (should-error (cljbang-test--eval "(set! (foo) 1)")))


;;; Special forms

(ert-deftest cljbang-test-cond ()
  (should (eq :a (cljbang-test--eval "(cond (= 1 1) :a (= 2 2) :b)")))
  (should (eq :b (cljbang-test--eval "(cond (= 1 2) :a (= 2 2) :b)")))
  (should (eq :fallback (cljbang-test--eval "(cond (= 1 2) :a :else :fallback)")))
  (should (null (cljbang-test--eval "(cond (= 1 2) :a)"))))

(ert-deftest cljbang-test-cond-odd-forms-error ()
  (should-error (cljbang-test--eval "(cond (= 1 1))")))

(ert-deftest cljbang-test-threading ()
  (should (= 9 (cljbang-test--eval "(-> 1 (+ 2) (* 3))")))
  (should (equal '(2 3) (cljbang-test--eval "(->> [1 2] (map inc))"))))

(ert-deftest cljbang-test-if-when-do ()
  (should (eq :y (cljbang-test--eval "(if true :y :n)")))
  (should (null (cljbang-test--eval "(when false :y)")))
  (should (= 2 (cljbang-test--eval "(do 1 2)"))))


;;; Core functions

(ert-deftest cljbang-test-first-second-rest ()
  (should (= 1 (cljbang-test--eval "(first [1 2])")))
  (should (= 2 (cljbang-test--eval "(second [1 2])")))
  (should (null (cljbang-test--eval "(second [1])")))
  (should (null (cljbang-test--eval "(second nil)")))
  (should (equal '(2 3) (cljbang-test--eval "(rest [1 2 3])"))))

(ert-deftest cljbang-test-nth ()
  (should (= 2 (cljbang-test--eval "(nth [1 2 3] 1)")))
  (should (eq :none (cljbang-test--eval "(nth [1] 5 :none)")))
  (should (null (cljbang-test--eval "(nth nil 0)")))
  (should-error (cljbang-test--eval "(nth [1] 5)")))

(ert-deftest cljbang-test-name ()
  (should (equal "foo" (cljbang-test--eval "(name :foo)")))
  (should (equal "foo" (cljbang-test--eval "(name :my.ns/foo)")))
  (should (equal "foo" (cljbang-test--eval "(name 'foo)")))
  (should (equal "foo" (cljbang-test--eval "(name \"foo\")"))))

(ert-deftest cljbang-test-subs-rejects-negative ()
  "Elisp substring counts negatives from the end; Clojure's subs does not."
  (should (equal "el" (cljbang-test--eval "(subs \"hello\" 1 3)")))
  (should (equal "" (cljbang-test--eval "(subs \"hello\" 5)")))
  (should-error (cljbang-test--eval "(subs \"hello\" -1)"))
  (should-error (cljbang-test--eval "(subs \"hello\" 0 -1)")))

(ert-deftest cljbang-test-count ()
  (should (= 3 (cljbang-test--eval "(count [1 2 3])")))
  (should (= 2 (cljbang-test--eval "(count {:a 1 :b 2})")))
  (should (= 0 (cljbang-test--eval "(count nil)"))))

(ert-deftest cljbang-test-str ()
  (should (equal "ab" (cljbang-test--eval "(str \"a\" \"b\")")))
  (should (equal "" (cljbang-test--eval "(str nil)"))))


;;; Sets, maps, keywords and vectors as functions

(ert-deftest cljbang-test-set-as-function ()
  (should (= 1 (cljbang-test--eval "(#{1 2 3} 1)")))
  (should (null (cljbang-test--eval "(#{1 2 3} 9)")))
  (should (= 1 (cljbang-test--eval "(let [s #{1 2}] (s 1))"))))

(ert-deftest cljbang-test-map-as-function ()
  (should (= 1 (cljbang-test--eval "({:a 1} :a)")))
  (should (= 42 (cljbang-test--eval "({:a 1} :b 42)")))
  (should (= 5 (cljbang-test--eval "(let [m {:a 5}] (m :a))"))))

(ert-deftest cljbang-test-keyword-as-function ()
  (should (= 1 (cljbang-test--eval "(:a {:a 1})")))
  (should (null (cljbang-test--eval "(:b {:a 1})")))
  (should (= 7 (cljbang-test--eval "(:b {:a 1} 7)")))
  (should (= 9 (cljbang-test--eval "(let [k :a] (k {:a 9}))"))))

(ert-deftest cljbang-test-vector-as-function ()
  (should (= 20 (cljbang-test--eval "([10 20 30] 1)"))))

(ert-deftest cljbang-test-callable-in-higher-order-position ()
  (should (equal '(1 3) (cljbang-test--eval "(filter #{1 3} [1 2 3 4])")))
  (should (equal '(1 2) (cljbang-test--eval "(map :a [{:a 1} {:a 2}])"))))

(ert-deftest cljbang-test-ordinary-calls-unaffected ()
  (should (= 42 (cljbang-test--eval "(let [f (fn [x] (* x 2))] (f 21))")))
  (should (equal '(2 3) (cljbang-test--eval "(map (fn [x] (inc x)) [1 2])")))
  (should (= 6 (cljbang-test--eval "(reduce + 0 [1 2 3])")))
  (should (= 2 (cljbang-test--eval "(let [f inc] (f 1))"))))


;;; Interop

(ert-deftest cljbang-test-elisp-interop-is-direct ()
  "Names cljbang does not claim compile to a plain elisp call."
  (should (equal '(upcase "ab") (cljbang-compile '(upcase "ab"))))
  (should (equal '(cljbang-str "a") (cljbang-compile '(str "a")))))


;;; The clj! macro

(ert-deftest cljbang-test-clj-macro ()
  (should (= 1 (eval (read "(clj! (get {:a 1} :a))") t)))
  (should (= 5 (eval (read "(clj! (let [{:keys [a]} {:a 5}] a))") t)))
  (should (= 3 (eval (read "(clj! (count (hash-set 1 2 3)))") t))))

(ert-deftest cljbang-test-clj-macro-has-no-dispatch-literals ()
  "#{ and #( need source text, which the macro never sees."
  (should-error (read "(clj! (count #{1 2}))"))
  (should-error (read "(clj! (map #(+ % 1) [1]))")))


;;; Loading files

(defconst cljbang-test--root
  ;; load-file-name is bound only while this file loads, not when a test runs
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Project root, captured at load time.")

(defun cljbang-test--example (name)
  "Absolute path of example NAME."
  (expand-file-name (concat "examples/" name) cljbang-test--root))

(ert-deftest cljbang-test-load-file ()
  "Loading defines the file's vars, which stay callable afterwards."
  (cljbang-load-file (cljbang-test--example "full-syntax.clj"))
  (should (eq :bob (cljbang-test--eval "(winner scores)")))
  (cljbang-load-file (cljbang-test--example "fast.clj"))
  (should (= 55 (cljbang-test--eval "(fast/fib 10)"))))

(ert-deftest cljbang-test-load-file-restores-ns ()
  "An (ns ...) inside a loaded file does not leak into the caller."
  (let ((before cljbang--current-ns))
    (cljbang-load-file (cljbang-test--example "fast.clj"))
    (should (equal before cljbang--current-ns))))

;;; Namespaces

(ert-deftest cljbang-test-ns-interns-munged-names ()
  "(ns foo) makes defn intern foo--name, callable from elisp."
  (cljbang-test--eval "(ns nstest) (defn triple [x] (* 3 x))")
  (should (fboundp 'nstest--triple))
  (should (= 9 (nstest--triple 3)))
  (setq cljbang--current-ns nil))

(ert-deftest cljbang-test-ns-qualified-call ()
  (cljbang-test--eval "(ns nsq) (defn dbl [x] (* 2 x))")
  (setq cljbang--current-ns nil)
  (should (= 8 (cljbang-test--eval "(nsq/dbl 4)"))))

(ert-deftest cljbang-test-ns-alias ()
  (cljbang-test--eval "(ns aliased (:require [clojure.string :as str]))")
  (should (equal "a,b" (cljbang-test--eval "(str/join \",\" [\"a\" \"b\"])")))
  (setq cljbang--current-ns nil))

(ert-deftest cljbang-test-as-alias-is-accepted ()
  "el/ resolves to the host whatever an alias claims."
  (cljbang-test--eval "(ns withalias (:require [cljbang.el :as-alias el]))")
  (should (equal "AB" (cljbang-test--eval "(el/upcase \"ab\")")))
  (setq cljbang--current-ns nil))


;;; Interactive evaluation

(ert-deftest cljbang-test-eval-last-sexp ()
  "Point after a form evaluates it as Clojure and shows an overlay."
  (with-temp-buffer
    (setq-local cljbang-whole-buffer t)
    (insert "(get {:a 41} :a)")
    (cljbang-eval-last-sexp)
    (should (= 1 (length cljbang--result-overlays)))
    (should (string-match-p "41"
                            (overlay-get (car cljbang--result-overlays)
                                         'after-string)))))

(ert-deftest cljbang-test-eval-last-sexp-heeds-buffer-ns ()
  (with-temp-buffer
    (setq-local cljbang-whole-buffer t)
    (insert "(ns buffns)\n(defn quad [x] (* 4 x))")
    (cljbang-eval-last-sexp)
    (should (fboundp 'buffns--quad))
    (should (= 12 (buffns--quad 3)))))

(provide 'cljbang-test)
;;; cljbang-test.el ends here
