;;; cljbang-test.el --- Tests for cljbang -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cljbang)
(require 'cljbang-mode)

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


(ert-deftest cljbang-test-quoted-collection-literals ()
  "The reader binds quote to the symbol holding the open brace, so '{:a 1}
arrives split.  Quoting has to be reapplied after the braces are rebuilt."
  (should (= 1 (cljbang-test--eval "(count '{:a 1})")))
  (should (= 2 (cljbang-test--eval "(count '#{1 2})")))
  ;; contents stay unevaluated, as in Clojure
  (should (eq 'foo (cljbang-test--eval "(get '{:a foo} :a)")))
  (should (equal [1 x] (cljbang-test--eval "(get '{:a [1 x]} :a)")))
  ;; a nested literal is still a collection, not a quoted list
  (should (= 1 (cljbang-test--eval "(count (get '{:a {:b c}} :a))")))
  (should (eq 'c (cljbang-test--eval "(get (get '{:a {:b c}} :a) :b)"))))

(ert-deftest cljbang-test-ns-attr-map ()
  "An ns attr-map, which is where a clj-kondo config goes, must not break."
  (should (cljbang-test--eval
           "(ns attrs {:clj-kondo/config '{:linters {:foo {:level :off}}}}) :ok"))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-get-reads-native-elisp-data ()
  "get, and so destructuring, reads alists and plists as well as maps."
  (should (= 1 (cljbang-test--eval "(get '((:a . 1)) :a)")))
  (should (= 1 (cljbang-test--eval "(:a '((:a . 1)))")))
  (should (cljbang-test--eval "(contains? '((:a . 1)) :a)"))
  (should-not (cljbang-test--eval "(contains? '((:a . 1)) :z)")))

(ert-deftest cljbang-test-destructure-native-elisp-data ()
  (should (equal '(1 2) (cljbang-test--eval
                         "(let [{:keys [a b]} '((:a . 1) (:b . 2))] (list a b))")))
  (should (= 7 (cljbang-test--eval "((fn [{:keys [a]}] a) '((:a . 7)))"))))

(ert-deftest cljbang-test-get-tells-absent-from-nil ()
  "A key present with a nil value is not the same as a missing key."
  (should-not (cljbang-test--eval "(get '((:a . nil)) :a :fallback)"))
  (should (eq :fallback (cljbang-test--eval "(get '((:a . 1)) :z :fallback)"))))

(ert-deftest cljbang-test-lists-are-not-associative ()
  "A plain list is sequential, so get finds nothing in it, as in Clojure.
Only an alist reads as a map, since a plist cannot be told from a list of
keywords."
  (should-not (cljbang-test--eval "(get '(1 2 3) 0)"))
  (should-not (cljbang-test--eval "(get '(:a :b :c) :a)"))
  (should-not (cljbang-test--eval "(get '(:a 1) :a)"))
  (should (= 1 (cljbang-test--eval "(nth '(1 2 3) 0)")))
  (should (equal '(1 2) (cljbang-test--eval "(let [[a b] '(1 2)] (list a b))"))))

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


(ert-deftest cljbang-test-time-and-with-out-str-are-macros ()
  "Both are macros in Clojure, so the compiler does not know them."
  (should (cljbang--macro-function 'time))
  (should (cljbang--macro-function 'with-out-str))
  (should-not (member "time" cljbang--special-forms))
  (should-not (member "with-out-str" cljbang--special-forms)))

(ert-deftest cljbang-test-with-out-str ()
  (should (equal "a\nb\n"
                 (cljbang-test--eval "(with-out-str (println \"a\") (println \"b\"))"))))

(ert-deftest cljbang-test-time ()
  "Returns the value, prints the elapsed time, and evaluates once."
  (should (= 3 (cljbang-test--eval "(time (+ 1 2))")))
  (should (string-match-p "Elapsed time: .* msecs"
                          (cljbang-test--eval "(with-out-str (time (+ 1 2)))")))
  (defvar cljbang-test--time-calls 0)
  (setq cljbang-test--time-calls 0)
  (defalias 'cljbang-test--bump
    (lambda () (setq cljbang-test--time-calls (1+ cljbang-test--time-calls))))
  (cljbang-test--eval "(with-out-str (time (cljbang-test--bump)))")
  (should (= 1 cljbang-test--time-calls)))

;;; Regexes

(ert-deftest cljbang-test-regex-literal ()
  (should (cljbang--regex-p (cljbang-test--eval "#\"a+\"")))
  (should (equal "a+" (cljbang--regex-string (cljbang-test--eval "#\"a+\"")))))

(ert-deftest cljbang-test-re-find ()
  (should (equal "aaa" (cljbang-test--eval "(re-find #\"a+\" \"baaac\")")))
  (should (null (cljbang-test--eval "(re-find #\"z\" \"abc\")")))
  ;; groups come back as a vector, whole match first
  (should (equal ["aab" "aa" "b"]
                 (cljbang-test--eval "(re-find #\"\\\\(a+\\\\)\\\\(b\\\\)\" \"xaab\")"))))

(ert-deftest cljbang-test-re-matches ()
  (should (equal "aaa" (cljbang-test--eval "(re-matches #\"a+\" \"aaa\")")))
  ;; must match all of the string
  (should (null (cljbang-test--eval "(re-matches #\"a+\" \"baaa\")"))))

(ert-deftest cljbang-test-re-seq ()
  (should (equal '("ab" "ac") (cljbang-test--eval "(re-seq #\"a.\" \"abac\")"))))

(ert-deftest cljbang-test-replace-dispatches-on-match-type ()
  "A string match is literal and a regex is not, as in Clojure."
  (should (equal "a#b#" (cljbang-test--eval "(str/replace \"a1b2\" #\"[0-9]\" \"#\")")))
  (should (equal "a!b" (cljbang-test--eval "(str/replace \"a.b\" \".\" \"!\")")))
  (should (equal "ba" (cljbang-test--eval "(str/replace-first \"aa\" #\"a\" \"b\")")))
  (should (equal ["a" "b" "c"] (cljbang-test--eval "(str/split \"a1b2c\" #\"[0-9]\")"))))

(ert-deftest cljbang-test-regex-rewrite-skips-strings ()
  (should (equal "#\"not a regex\"" (cljbang-test--eval "(str \"#\\\"not a regex\\\"\")"))))

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


(ert-deftest cljbang-test-warns-on-unresolved-qualified-name ()
  "A typo should be caught at compile time, an autoload should not warn."
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type msg &rest _) (push msg warnings))))
      (defalias 'wt-known (lambda () :x))
      (cljbang-compile '(wt/known))
      (should-not warnings)
      (cljbang-compile '(wt/missing))
      (should (= 1 (length warnings)))
      (should (string-match-p "wt-missing" (car warnings))))))

(ert-deftest cljbang-test-no-warning-for-own-namespace ()
  "A var cljbang interned is fine even before it is evaluated."
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type msg &rest _) (push msg warnings))))
      (cljbang-eval-string "(ns selftest) (defn a [] 1)")
      (cljbang-compile '(selftest/a))
      (should-not warnings)))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-warning-can-be-turned-off ()
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type msg &rest _) (push msg warnings))))
      (let ((cljbang-warn-unresolved nil))
        (cljbang-compile '(nothing/here)))
      (should-not warnings))))

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


(ert-deftest cljbang-test-docstrings ()
  "A Clojure docstring goes where elisp keeps one, so C-h f finds it."
  (cljbang-test--eval "(defn dt-fn \"Doubles X.\" [x] (* x 2))")
  (should (equal "Doubles X." (documentation 'dt-fn)))
  (should (= 42 (dt-fn 21)))
  (should (equal '(x) (help-function-arglist 'dt-fn)))
  (cljbang-test--eval "(def dt-var \"The answer.\" 42)")
  (should (equal "The answer." (get 'dt-var 'variable-documentation)))
  (should (= 42 dt-var))
  ;; and a string as the only body form is still a return value
  (cljbang-test--eval "(defn dt-plain [x] \"just a string\")")
  (should (equal "just a string" (dt-plain 1))))

(ert-deftest cljbang-test-callable-from-elisp ()
  "The promise: what a .clj file defines, elisp can call."
  (cljbang-test--eval "(defn ce-plain [x] (* x 2))
                       (defn ce-varargs [a & rest] (list a rest))
                       (defn ce-destructured [{:keys [a]}] a)
                       (defn ce-cmd [] (interactive) :ran)")
  (should (= 42 (ce-plain 21)))
  (should (equal '(1 (2 3)) (ce-varargs 1 2 3)))
  (should (commandp 'ce-cmd))
  (should-error (ce-plain 1 2))
  ;; a map parameter wants a cljbang map, not an alist
  (should (= 7 (ce-destructured (cljbang-hash-map :a 7)))))

;;; Syntax quote

(ert-deftest cljbang-test-syntax-quote ()
  (should (equal '(a b c) (cljbang-test--eval "`(a b c)")))
  (should (equal '(a 1) (cljbang-test--eval "(let [x 1] `(a ~x))")))
  (should (= 5 (cljbang-test--eval "(let [x 5] `~x)")))
  (should (equal '(a 3) (cljbang-test--eval "`(a ~(+ 1 2))")))
  (should (null (cljbang-test--eval "`()"))))

(ert-deftest cljbang-test-syntax-quote-splices ()
  (should (equal '(a 1 2 b) (cljbang-test--eval "(let [xs [1 2]] `(a ~@xs b))")))
  (should (equal [1 2 3] (cljbang-test--eval "(let [xs [1 2]] `[~@xs 3])")))
  (should (equal '(1 2) (cljbang-test--eval "(let [xs [1 2]] `(~@xs))")))
  (should (equal '(a) (cljbang-test--eval "(let [xs []] `(a ~@xs))"))))

(ert-deftest cljbang-test-syntax-quote-over-collections ()
  (should (equal [a 1] (cljbang-test--eval "(let [x 1] `[a ~x])")))
  (should (= 1 (cljbang-test--eval "(let [x 1] (get `{:a ~x} :a))")))
  (should (= 2 (cljbang-test--eval "(count `#{1 2})")))
  (should (equal '(a (b (c 2))) (cljbang-test--eval "`(a (b (c ~(+ 1 1))))"))))

(ert-deftest cljbang-test-syntax-quote-qualifies-to-the-namespace ()
  "A macro expands elsewhere, so an unqualified name settles here."
  (cljbang-test--eval "(ns sqns) (defn thing [] :x)")
  (should (eq 'sqns-thing (cljbang-test--eval "`thing")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-syntax-quote-does-not-need-the-var-yet ()
  "As in Clojure, where the var may be defined after the macro."
  (cljbang-test--eval "(ns sqlater)")
  (should (eq 'sqlater-not-yet (cljbang-test--eval "`not-yet")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-syntax-quote-leaves-special-forms-bare ()
  "The compiler matches these before it resolves anything, the way Clojure
leaves if and do alone.  A var of that name cannot take one."
  (cljbang-test--eval "(ns sqbare)")
  (should (equal '(if a b) (cljbang-test--eval "`(if ~'a ~'b)")))
  (should (eq 'let (cljbang-test--eval "`let")))
  (should (equal '(fn [x] x) (cljbang-test--eval "`(fn [~'x] ~'x)")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-syntax-quote-names-a-builtin-macro-in-its-namespace ()
  "As Clojure writes clojure.core/when, so a macro of that name elsewhere
cannot take it."
  (cljbang-test--eval "(ns sqmac)")
  (should (eq 'cljbang.core/when (cljbang-test--eval "`when")))
  (should (eq 'cljbang.core/-> (cljbang-test--eval "`->")))
  (should (equal '(cljbang.core/when t 1) (cljbang-test--eval "`(when true 1)")))
  (should (eq :y (cljbang-test--eval "(cljbang.core/when true :y)")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-a-builtin-macro-in-a-template-is-not-captured ()
  (let ((dir (make-temp-file "cljbang-hij" t)))
    (unwind-protect
        (let ((cljbang-load-path (list dir)))
          (write-region "(ns wlib)\n(defmacro guard [x] `(when ~x (inc ~x)))\n"
                        nil (expand-file-name "wlib.clj" dir) nil 'quiet)
          (write-region (concat "(ns wuser (:require [wlib :as w]))\n"
                                "(defmacro when [tst & body] :hijacked)\n"
                                "(defn go [] [(w/guard 1) (when true :mine)])\n")
                        nil (expand-file-name "wuser.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "wlib.clj" dir))
          (cljbang--set-current-ns nil)
          (cljbang-load-file (expand-file-name "wuser.clj" dir))
          ;; wlib keeps cljbang's when, wuser gets its own
          (should (equal [2 :hijacked] (wuser-go))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-syntax-quote-resolves-a-core-function ()
  "A var of that name where the macro expands would otherwise take it."
  (cljbang-test--eval "(ns sqcore)")
  (should (eq '1+ (cljbang-test--eval "`inc")))
  (should (eq 'cljbang-map (cljbang-test--eval "`map")))
  (should (eq 'cljbang-str (cljbang-test--eval "`str")))
  (should (equal '(cljbang-map 1+ [1]) (cljbang-test--eval "`(map inc [1])")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-a-core-function-in-a-macro-is-not-captured ()
  (let ((dir (make-temp-file "cljbang-cap" t)))
    (unwind-protect
        (let ((cljbang-load-path (list dir)))
          (write-region "(ns caplib)\n(defmacro capbump [x] `(inc ~x))\n"
                        nil (expand-file-name "caplib.clj" dir) nil 'quiet)
          (write-region (concat "(ns capuser (:require [caplib :as c]))\n"
                                "(defn inc [n] :captured)\n"
                                "(defn go [] (c/capbump 1))\n")
                        nil (expand-file-name "capuser.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "caplib.clj" dir))
          (cljbang--set-current-ns nil)
          (cljbang-load-file (expand-file-name "capuser.clj" dir))
          (should (= 2 (capuser-go))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-syntax-quote-keeps-parameter-syntax ()
  (cljbang-test--eval "(ns sqamp)")
  (should (eq '& (nth 1 (append (nth 1 (cljbang-test--eval "`(fn [a & b] a)")) nil))))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-syntax-quote-needs-el-for-a-host-name ()
  "An unqualified name is a var of the namespace, so elisp needs el/."
  (cljbang-test--eval "(ns sqhost)")
  (should (eq 'sqhost-propertize (cljbang-test--eval "`propertize")))
  (should (equal '(message "hi") (cljbang-test--eval "`(el/message \"hi\")")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-syntax-quote-expands-an-alias ()
  (cljbang-test--eval "(ns sqalias)")
  (should (eq 'cljbang-string-join (cljbang-test--eval "`str/join")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-a-macro-expands-in-another-namespace ()
  "The macro's own namespace is what its unqualified names must mean."
  (let ((dir (make-temp-file "cljbang-sq" t)))
    (unwind-protect
        (let ((cljbang-load-path (list dir)))
          (write-region (concat "(ns sqlib)\n"
                                "(defn helper [x] (str \"helped \" x))\n"
                                "(defmacro use-helper [x] `(helper ~x))\n")
                        nil (expand-file-name "sqlib.clj" dir) nil 'quiet)
          (write-region (concat "(ns squser (:require [sqlib :as a]))\n"
                                "(defn go [] (a/use-helper \"u\"))\n")
                        nil (expand-file-name "squser.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "sqlib.clj" dir))
          (cljbang--set-current-ns nil)
          (cljbang-load-file (expand-file-name "squser.clj" dir))
          (should (equal "helped u" (squser-go))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-auto-gensym ()
  "x# is one fresh name per template, which is what stops capture."
  (let ((form (cljbang-test--eval "`(let [x# 1] x#)")))
    (should (eq (nth 0 form) 'let))
    (should (eq (aref (nth 1 form) 0) (nth 2 form)))
    (should-not (eq (aref (nth 1 form) 0) (intern "x#"))))
  (should (not (equal (cljbang-test--eval "`x#") (cljbang-test--eval "`x#")))))

(ert-deftest cljbang-test-macros-written-with-syntax-quote ()
  (should (= 9 (cljbang-test--eval "(defmacro sq2 [x] `(* ~x ~x)) (sq2 (+ 1 2))")))
  (should (= 2 (cljbang-test--eval
                "(defmacro wh [t & body] `(if ~t (do ~@body) nil)) (wh true 1 2)")))
  (should (equal [1 2] (cljbang-test--eval "(defmacro v2 [& xs] `[~@xs]) (v2 1 2)"))))

(ert-deftest cljbang-test-auto-gensym-avoids-capture ()
  (should (= 5 (cljbang-test--eval
                "(defmacro my-or [a b] `(let [v# ~a] (if v# v# ~b)))
                 (let [v 5] (my-or nil v))"))))

(ert-deftest cljbang-test-unquote-outside-a-syntax-quote ()
  (should-error (cljbang-test--eval "~x"))
  (should-error (cljbang-test--eval "(list ~x)")))

(ert-deftest cljbang-test-nested-syntax-quote-is-refused ()
  (should-error (cljbang-test--eval "``a")))

(ert-deftest cljbang-test-reader-macros-are-text-only ()
  "A backtick, tilde or @ inside a string or comment is left alone."
  (should (equal "a ~b and `c and @d" (cljbang-test--eval "(str \"a ~b and `c and @d\")")))
  (should (equal "x#" (cljbang-test--eval "(str \"x#\")")))
  (should (equal '(a "~not-unquoted" b) (cljbang-test--eval "`(a \"~not-unquoted\" b)")))
  (should (eq :ok (cljbang-test--eval ";; `backtick ~tilde @at x#\n:ok"))))

;;; Macros

(ert-deftest cljbang-test-defmacro ()
  "A macro sees its arguments unevaluated and its expansion is compiled."
  (should (= 6 (cljbang-test--eval "(defmacro twice [x] (list '+ x x)) (twice 3)")))
  (should (= 3 (cljbang-test--eval "(defmacro ident [x] x) (ident (+ 1 2))"))))

(ert-deftest cljbang-test-defmacro-controls-evaluation ()
  "The point of a macro: the body is not evaluated unless the expansion says so."
  (should (eq :ok (cljbang-test--eval
                   "(defmacro unless-neg [n body] (list 'if (list '< n 0) nil body))
                    (unless-neg 5 :ok)"))))

(ert-deftest cljbang-test-a-name-collision-warns ()
  "Munging is not reversible, so two namespaces can want one elisp name."
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (cljbang-test--eval "(ns coll-a-b) (defn c [] :first)")
      (should (null warnings))
      ;; same var again is a reload, not a collision
      (cljbang-test--eval "(ns coll-a-b) (defn c [] :again)")
      (should (null warnings))
      (cljbang-test--eval "(ns coll-a) (defn b-c [] :second)")
      (should (= 1 (length warnings)))
      (should (string-match-p "coll-a/b-c interns coll-a-b-c" (car warnings)))
      (should (string-match-p "already coll-a-b/c" (car warnings)))))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-what-a-symbol-was-interned-as ()
  (cljbang-test--eval "(ns internedns) (defn thing [] :x)")
  (should (equal '("internedns" . "thing") (cljbang--interned-as 'internedns-thing)))
  (should (null (cljbang--interned-as 'not-a-cljbang-name)))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-a-macro-belongs-to-its-namespace ()
  "A macro of one namespace must not shadow a name in another."
  (let ((dir (make-temp-file "cljbang-mac" t)))
    (unwind-protect
        (let ((cljbang-load-path (list dir)))
          (write-region "(ns maclib)\n(defmacro dbl [x] (list '* x 2))\n"
                        nil (expand-file-name "maclib.clj" dir) nil 'quiet)
          (write-region (concat "(ns macuser (:require [maclib :as m]))\n"
                                "(defn dbl [n] :a-function)\n"
                                "(defn go [] [(m/dbl 21) (dbl 5)])\n")
                        nil (expand-file-name "macuser.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "maclib.clj" dir))
          (cljbang--set-current-ns nil)
          ;; not registered outside the namespace that defined it
          (should-error (cljbang-test--eval "(dbl 3)"))
          (cljbang-load-file (expand-file-name "macuser.clj" dir))
          (should (equal [42 :a-function] (macuser-go))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-builtin-macros-reach-every-namespace ()
  (cljbang-test--eval "(ns macplain)")
  (should (eq :y (cljbang-test--eval "(when true :y)")))
  (should (= 2 (cljbang-test--eval "(-> 1 inc)")))
  (should (eq :a (cljbang-test--eval "(cond (= 1 1) :a)")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-macros-live-in-the-namespace-state ()
  (cljbang-test--eval "(ns macstate) (defmacro mine [x] x)")
  (should (gethash "mine" (cljbang--ns-macro-table "macstate")))
  (should (null (gethash "mine" (cljbang--ns-macro-table cljbang--core-ns))))
  (should (gethash "when" (cljbang--ns-macro-table cljbang--core-ns)))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-defmacro-in-a-namespace ()
  (should (= 40 (cljbang-test--eval "(ns mns) (defmacro m1 [x] (list '* x 10)) (m1 4)")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-defmacro-runaway-is-caught ()
  (should-error (cljbang-test--eval "(defmacro loopy [x] (list 'loopy x)) (loopy 1)")))

(ert-deftest cljbang-test-local-binding-shadows-a-macro ()
  "A let-bound name is a value, not a macro call."
  (should (= 5 (cljbang-test--eval
                "(defmacro shadowed [x] (list '+ x 100))
                 (let [shadowed (fn [n] n)] (shadowed 5))"))))

(ert-deftest cljbang-test-truthiness ()
  "nil is the only false value in elisp, and an empty list is nil."
  (should (eq :y (cljbang-test--eval "(if 0 :y :n)")))
  (should (eq :y (cljbang-test--eval "(if \"\" :y :n)")))
  (should (eq :y (cljbang-test--eval "(if [] :y :n)")))
  (should (eq :y (cljbang-test--eval "(if {} :y :n)")))
  (should (eq :n (cljbang-test--eval "(if false :y :n)")))
  ;; Clojure says :y here, and elisp cannot, since '() is nil
  (should (eq :n (cljbang-test--eval "(if (list) :y :n)"))))

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

(ert-deftest cljbang-test-if-let ()
  (should (= 1 (cljbang-test--eval "(if-let [x 1] x :n)")))
  (should (eq :n (cljbang-test--eval "(if-let [x nil] x :n)")))
  (should (null (cljbang-test--eval "(if-let [x nil] x)")))
  (should (eq :n (cljbang-test--eval "(if-let [x (list)] :y :n)"))))

(ert-deftest cljbang-test-when-let ()
  (should (= 6 (cljbang-test--eval "(when-let [x 5] (inc x))")))
  (should (eq :b (cljbang-test--eval "(when-let [x 1] :a :b)")))
  (should (null (cljbang-test--eval "(when-let [x nil] :never)"))))

(ert-deftest cljbang-test-if-let-destructures ()
  (should (equal "h" (cljbang-test--eval "(when-let [{:keys [host]} {:host \"h\"}] host)")))
  (should (= 3 (cljbang-test--eval "(if-let [[a b] [1 2]] (+ a b) :n)")))
  (should (eq :n (cljbang-test--eval "(if-let [{:keys [a]} nil] a :n)"))))

(ert-deftest cljbang-test-if-let-evaluates-the-test-once ()
  (should (= 1 (cljbang-test--eval
                "(def calls 0)
                 (defn bump [] (set! calls (inc calls)) :v)
                 (if-let [x (bump)] x)
                 calls"))))

(ert-deftest cljbang-test-if-let-takes-one-binding-pair ()
  "Clojure's if-let binds one pair, unlike elisp's if-let*."
  (should-error (cljbang-test--eval "(if-let [x 1 y 2] x :n)")))

(ert-deftest cljbang-test-doseq ()
  (should (equal "1\n2\n3\n"
                 (cljbang-test--eval "(with-out-str (doseq [x [1 2 3]] (println x)))")))
  (should (equal "1\n2\n"
                 (cljbang-test--eval "(with-out-str (doseq [x (list 1 2)] (println x)))")))
  (should (equal "" (cljbang-test--eval "(with-out-str (doseq [x nil] (println :never)))")))
  (should (null (cljbang-test--eval "(doseq [x [1]] :v)"))))

(ert-deftest cljbang-test-doseq-destructures ()
  (should (equal "1 2\n"
                 (cljbang-test--eval "(with-out-str (doseq [[a b] [[1 2]]] (println a b)))")))
  (should (equal "1\n"
                 (cljbang-test--eval "(with-out-str (doseq [{:keys [a]} [{:a 1}]] (println a)))"))))

(ert-deftest cljbang-test-doseq-nests-later-pairs ()
  (should (equal "1 :a\n1 :b\n2 :a\n2 :b\n"
                 (cljbang-test--eval
                  "(with-out-str (doseq [x [1 2] y [:a :b]] (println x y)))"))))

(ert-deftest cljbang-test-doseq-when ()
  (should (equal "1\n3\n"
                 (cljbang-test--eval
                  "(with-out-str (doseq [x [1 2 3] :when (odd? x)] (println x)))")))
  (should (equal "" (cljbang-test--eval
                     "(with-out-str (doseq [x [1] :when false] (println :never)))"))))

(ert-deftest cljbang-test-doseq-let ()
  (should (equal "10\n20\n"
                 (cljbang-test--eval
                  "(with-out-str (doseq [x [1 2] :let [y (* x 10)]] (println y)))")))
  (should (equal "1\n2\n"
                 (cljbang-test--eval
                  "(with-out-str (doseq [x [1 2] :let [{:keys [a]} {:a x}]] (println a)))"))))

(ert-deftest cljbang-test-doseq-modifiers-scope-over-the-rest ()
  (should (equal "20\n30\n"
                 (cljbang-test--eval
                  "(with-out-str (doseq [x [1 2 3] :let [y (* x 10)] :when (> y 15)]
                                   (println y)))")))
  (should (equal "1 :a\n1 :b\n"
                 (cljbang-test--eval
                  "(with-out-str (doseq [x [1 2] :when (odd? x) y [:a :b]] (println x y)))"))))

(ert-deftest cljbang-test-doseq-rejects-unsupported-modifiers ()
  ":while is not implemented, and must not read as a pattern."
  (should-error (cljbang-test--eval "(doseq [x [1] :while (odd? x)] x)"))
  (should-error (cljbang-test--eval "(doseq [:when true x [1]] x)"))
  (should-error (cljbang-test--eval "(doseq [x] x)")))

(ert-deftest cljbang-test-dotimes ()
  (should (equal "0\n1\n2\n"
                 (cljbang-test--eval "(with-out-str (dotimes [i 3] (println i)))")))
  (should (equal "" (cljbang-test--eval "(with-out-str (dotimes [i 0] (println :never)))")))
  (should (null (cljbang-test--eval "(dotimes [i 3] :v)")))
  (should-error (cljbang-test--eval "(dotimes [i 1 j 2] i)")))

(ert-deftest cljbang-test-dotimes-binding-does-not-leak ()
  (should (= 9 (cljbang-test--eval "(let [i 9] (dotimes [i 2] i) i)"))))

(ert-deftest cljbang-test-loops-see-the-enclosing-scope ()
  (should (= 6 (cljbang-test--eval "(let [n 0] (doseq [x [1 2 3]] (set! n (+ n x))) n)")))
  (should (= 3 (cljbang-test--eval "(let [n 0] (dotimes [i 3] (set! n (inc n))) n)"))))

(ert-deftest cljbang-test-try-catch ()
  (should (= 1 (cljbang-test--eval "(try 1)")))
  (should (= 1 (cljbang-test--eval "(try 1 (catch error e :n))")))
  (should (= 5 (cljbang-test--eval "(try (throw 5) (catch error e e))")))
  (should (eq :x (cljbang-test--eval "(try (throw :x) (catch :default e e))"))))

(ert-deftest cljbang-test-throw-carries-any-value ()
  "Clojure catches back what was thrown, so a map arrives as a map."
  (should (= 1 (cljbang-test--eval "(try (throw {:a 1}) (catch error e (get e :a)))")))
  (should (equal "s" (cljbang-test--eval "(try (throw \"s\") (catch error e e))"))))

(ert-deftest cljbang-test-catch-binds-elisp-errors-as-they-come ()
  (should (equal "boom" (cljbang-test--eval
                         "(try (el/error \"boom\") (catch error e (el/error-message-string e)))")))
  (should (eq :wta (cljbang-test--eval "(try (el/car 1) (catch wrong-type-argument e :wta))"))))

(ert-deftest cljbang-test-catch-picks-the-matching-clause ()
  (should (eq :err (cljbang-test--eval
                    "(try (el/car 1) (catch arith-error e :ae) (catch error e :err))")))
  (should-error (cljbang-test--eval
                 "(try (el/signal 'arith-error nil) (catch wrong-type-argument e :no))")))

(ert-deftest cljbang-test-finally ()
  (should (equal ":c\n:f\n"
                 (cljbang-test--eval
                  "(with-out-str (try (throw 1) (catch error e (println :c)) (finally (println :f))))")))
  (should (= 1 (cljbang-test--eval "(try 1 (finally 99))")))
  (should (equal ":f\n" (cljbang-test--eval
                         "(with-out-str (try 1 (finally (println :f))))"))))

(ert-deftest cljbang-test-finally-runs-before-the-error-propagates ()
  (should (equal ":f\n"
                 (cljbang-test--eval
                  "(with-out-str (try (try (throw 1) (finally (println :f)))
                                      (catch error e nil)))"))))

(ert-deftest cljbang-test-ex-info ()
  (should (equal "boom" (cljbang-test--eval
                         "(try (throw (ex-info \"boom\" {:a 1})) (catch error e (ex-message e)))")))
  (should (= 1 (cljbang-test--eval
                "(try (throw (ex-info \"boom\" {:a 1})) (catch error e (get (ex-data e) :a)))")))
  (should (equal "inner"
                 (cljbang-test--eval
                  "(try (throw (ex-info \"m\" {} (ex-info \"inner\" {})))
                     (catch error e (ex-message (ex-cause e))))"))))

(ert-deftest cljbang-test-ex-message-reads-elisp-errors ()
  (should (equal "native" (cljbang-test--eval
                           "(try (el/error \"native\") (catch error e (ex-message e)))")))
  (should (null (cljbang-test--eval "(try (el/error \"native\") (catch error e (ex-data e)))"))))

(ert-deftest cljbang-test-ex-accessors-return-nil-off-an-ex-info ()
  "As in Clojure, where ex-data of anything but an ex-info is nil."
  (should (null (cljbang-test--eval "(ex-data {:a 1})")))
  (should (null (cljbang-test--eval "(ex-message \"s\")")))
  (should (null (cljbang-test--eval "(ex-cause (ex-info \"m\" {}))")))
  (should (null (cljbang-test--eval "(try (throw 5) (catch error e (ex-message e)))"))))

(ert-deftest cljbang-test-try-rejects-jvm-class-names ()
  "Exception would compile but never match, since matching goes by error symbol."
  (should-error (cljbang-test--eval "(try (throw 5) (catch Exception e e))"))
  (should-error (cljbang-test--eval "(try (throw 5) (catch error))"))
  (should-error (cljbang-test--eval "(try (throw 1) (catch error e e) (println :after))")))

(ert-deftest cljbang-test-case ()
  (should (eq :a (cljbang-test--eval "(case 1 1 :a 2 :b)")))
  (should (eq :b (cljbang-test--eval "(case 2 1 :a 2 :b)")))
  (should (eq :fallback (cljbang-test--eval "(case 9 1 :a :fallback)")))
  (should (eq :yes (cljbang-test--eval "(case :k :k :yes :no)")))
  (should (eq :yes (cljbang-test--eval "(case \"s\" \"s\" :yes :no)")))
  (should (eq :two (cljbang-test--eval "(case (inc 1) 2 :two :other)"))))

(ert-deftest cljbang-test-case-does-not-evaluate-its-constants ()
  (should (eq :yes (cljbang-test--eval "(case 'foo foo :yes :no)"))))

(ert-deftest cljbang-test-case-list-constant-matches-any ()
  (should (eq :either (cljbang-test--eval "(case 2 (1 2) :either :no)")))
  (should (eq :no (cljbang-test--eval "(case 3 (1 2) :either :no)"))))

(ert-deftest cljbang-test-case-without-a-default-throws ()
  (should-error (cljbang-test--eval "(case 9 1 :a)")))

(ert-deftest cljbang-test-loop-recur ()
  (should (= 3 (cljbang-test--eval "(loop [i 0] (if (< i 3) (recur (inc i)) i))")))
  (should (equal [0 1 2] (cljbang-test--eval
                          "(loop [i 0 acc []] (if (< i 3) (recur (inc i) (conj acc i)) acc))")))
  (should (eq :done (cljbang-test--eval "(loop [] :done)"))))

(ert-deftest cljbang-test-recur-rebinds-simultaneously ()
  "Clojure rebinds every loop variable at once, so a swap swaps."
  (should (equal [2 1] (cljbang-test--eval
                        "(loop [a 1 b 2] (if (= a 1) (recur b a) [a b]))"))))

(ert-deftest cljbang-test-loop-destructures ()
  (should (equal [3 2] (cljbang-test--eval
                        "(loop [[a b] [1 2]] (if (< a 3) (recur [(inc a) b]) [a b]))")))
  (should (= 2 (cljbang-test--eval
                "(loop [{:keys [n]} {:n 0}] (if (< n 2) (recur {:n (inc n)}) n))"))))

(ert-deftest cljbang-test-loop-does-not-grow-the-stack ()
  (should (= 100000 (cljbang-test--eval
                     "(loop [i 0] (if (< i 100000) (recur (inc i)) i))"))))

(ert-deftest cljbang-test-recur-is-checked ()
  (should-error (cljbang-test--eval "(recur 1)"))
  (should-error (cljbang-test--eval "(loop [i 0] (recur 1 2))"))
  (should-error (cljbang-test--eval "(loop [i 0] ((fn [] (recur 1))))")))

(ert-deftest cljbang-test-recur-in-a-function ()
  "The parameters are the recur target, so a fn recurs to itself."
  (should (= 0 (cljbang-test--eval "((fn [x] (if (pos? x) (recur (dec x)) x)) 5)")))
  (should (= 0 (cljbang-test--eval
                "(defn countdown [x] (if (pos? x) (recur (dec x)) x)) (countdown 5)")))
  (should (= 6 (cljbang-test--eval
                "(defn sum [xs acc] (if (seq xs) (recur (rest xs) (+ acc (first xs))) acc))
                 (sum [1 2 3] 0)")))
  (should (= 3 (cljbang-test--eval
                "(defn g [{:keys [n]}] (if (< n 3) (recur {:n (inc n)}) n)) (g {:n 0})")))
  (should (= 6 (cljbang-test--eval
                "(defn h [x & xs] (if (seq xs) (recur (+ x (first xs)) (rest xs)) x))
                 (h 1 2 3)"))))

(ert-deftest cljbang-test-recur-in-a-function-does-not-grow-the-stack ()
  (should (= 100000 (cljbang-test--eval
                     "(defn f [x] (if (< x 100000) (recur (inc x)) x)) (f 0)"))))

(ert-deftest cljbang-test-multiple-arities ()
  (should (equal [:one :two]
                 (cljbang-test--eval "(defn f ([x] :one) ([x y] :two)) [(f 1) (f 1 2)]")))
  (should (equal [0 5 5]
                 (cljbang-test--eval
                  "(defn g ([] 0) ([x] x) ([x y] (+ x y))) [(g) (g 5) (g 2 3)]")))
  (should (= 11 (cljbang-test--eval
                 "(defn h ([x] (h x 10)) ([x y] (+ x y))) (h 1)")))
  (should (eq :two (cljbang-test--eval "((fn ([x] :one) ([x y] :two)) 1 2)"))))

(ert-deftest cljbang-test-arities-take-rest-and-destructuring ()
  (should (equal [:one 2]
                 (cljbang-test--eval
                  "(defn v ([x] :one) ([x & xs] (count xs))) [(v 1) (v 1 2 3)]")))
  (should (equal [7 [1 2]]
                 (cljbang-test--eval
                  "(defn d ([{:keys [a]}] a) ([a b] [a b])) [(d {:a 7}) (d 1 2)]"))))

(ert-deftest cljbang-test-each-arity-is-its-own-recur-target ()
  (should (= 5 (cljbang-test--eval
                "(defn r ([x] (r x 0))
                   ([x acc] (if (pos? x) (recur (dec x) (inc acc)) acc)))
                 (r 5)"))))

(ert-deftest cljbang-test-a-docstring-survives-multiple-arities ()
  (should (equal [:one :two]
                 (cljbang-test--eval
                  "(defn f \"the doc\" ([x] :one) ([x y] :two)) [(f 1) (f 1 2)]"))))

(ert-deftest cljbang-test-calling-an-arity-that-is-not-there ()
  (should-error (cljbang-test--eval "(defn f ([x] :one) ([x y] :two)) (f 1 2 3)")))

(ert-deftest cljbang-test-a-malformed-arity-is-rejected ()
  "These used to compile into something that failed only when called."
  (should-error (cljbang-test--eval "(defn f (x) :body)"))
  (should-error (cljbang-test--eval "(defn f ([x] :one) (:not-a-vector))"))
  (should-error (cljbang-test--eval "(defn f)"))
  (should-error (cljbang-test--eval "(fn)")))

(ert-deftest cljbang-test-a-function-without-recur-is-a-plain-lambda ()
  "The loop is only emitted when a recur asks for one."
  (should (equal '(lambda (x) (* x 2))
                 (cljbang-compile (car (cljbang--read-forms "(fn [x] (* x 2))"))))))

(ert-deftest cljbang-test-recur-checks-the-function-arity ()
  (should-error (cljbang-test--eval "((fn [x] (recur x x)) 1)"))
  (should-error (cljbang-test--eval "(defn bad [x] (+ 1 (recur x)))")))

(ert-deftest cljbang-test-recur-must-be-in-tail-position ()
  "Clojure refuses these, and running them would half update the loop."
  (should-error (cljbang-test--eval "(loop [i 0] (if (< i 3) (+ 1 (recur (inc i))) i))"))
  (should-error (cljbang-test--eval "(loop [i 0] (do (when (< i 3) (recur (inc i))) i))"))
  (should-error (cljbang-test--eval "(loop [i 0] (if (< i 3) (let [x (recur (inc i))] x) i))"))
  (should-error (cljbang-test--eval
                 "(loop [i 0 acc []] (if (< i 3) (conj (recur (inc i) acc) 9) acc))")))

(ert-deftest cljbang-test-recur-cannot-cross-a-try ()
  (should-error (cljbang-test--eval
                 "(loop [i 0] (if (< i 3) (try (recur (inc i)) (catch error e :c)) i))")))

(ert-deftest cljbang-test-recur-in-tail-position-still-passes ()
  "The check must not reject the shapes that are in tail position."
  (should (= 3 (cljbang-test--eval "(loop [i 0] (if (< i 3) (recur (inc i)) i))")))
  (should (= 3 (cljbang-test--eval
                "(loop [i 0] (if (< i 3) (let [n (inc i)] (recur n)) i))")))
  (should (= 3 (cljbang-test--eval
                "(loop [i 0] (cond (>= i 3) i :else (recur (inc i))))")))
  (should (= 3 (cljbang-test--eval
                "(loop [i 0] (if (< i 3) (do :ignored (recur (inc i))) i))")))
  (should (= 6 (cljbang-test--eval
                "(loop [i 0 acc 0] (if (< i 4) (recur (inc i) (+ acc i)) acc))"))))

(ert-deftest cljbang-test-some-threading ()
  (should (= 2 (cljbang-test--eval "(some-> 1 inc)")))
  (should (null (cljbang-test--eval "(some-> nil inc)")))
  (should (= 2 (cljbang-test--eval "(some-> {:a 1} (get :a) inc)")))
  (should (equal '(2) (cljbang-test--eval "(some->> [1] (map inc))")))
  (should (null (cljbang-test--eval "(some->> nil (map inc))"))))

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

(ert-deftest cljbang-test-last ()
  "Elisp last gives the last cons cell, Clojure's gives the last element."
  (should (= 3 (cljbang-test--eval "(last [1 2 3])")))
  (should (= 3 (cljbang-test--eval "(last '(1 2 3))")))
  (should (null (cljbang-test--eval "(last [])")))
  (should (null (cljbang-test--eval "(last nil)"))))

(ert-deftest cljbang-test-remove ()
  "Elisp remove deletes elements equal to its argument, Clojure's takes a predicate."
  (should (equal '(2) (cljbang-test--eval "(remove odd? [1 2 3])")))
  (should (equal '(2 4) (cljbang-test--eval "(remove #{1 3} [1 2 3 4])")))
  (should (null (cljbang-test--eval "(remove odd? nil)"))))

(ert-deftest cljbang-test-concat ()
  "Elisp concat over vectors gives a string, Clojure's concat gives a sequence."
  (should (equal '(1 2) (cljbang-test--eval "(concat [1] [2])")))
  (should (equal '(1 2 3) (cljbang-test--eval "(concat '(1) [2] '(3))")))
  (should (null (cljbang-test--eval "(concat)")))
  (should (equal '(1) (cljbang-test--eval "(concat [1] nil)"))))

(ert-deftest cljbang-test-sort ()
  (should (equal '(1 2 3) (cljbang-test--eval "(sort [3 1 2])")))
  (should (equal '("a" "b") (cljbang-test--eval "(sort [\"b\" \"a\"])")))
  (should (equal '(3 2 1) (cljbang-test--eval "(sort > [1 3 2])")))
  (should (null (cljbang-test--eval "(sort [])"))))

(ert-deftest cljbang-test-sort-copies ()
  "Elisp sort reorders its argument in place, Clojure's leaves it alone."
  (should (equal '(3 1 2)
                 (cljbang-test--eval "(let [v [3 1 2]] (sort v) (seq-into v 'list))"))))

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

(ert-deftest cljbang-test-equality-is-structural ()
  "Elisp equal compares hash tables by identity; Clojure's = does not."
  (should (cljbang-test--eval "(= {:a 1} {:a 1})"))
  (should (cljbang-test--eval "(= {[1 2] 1} {[1 2] 1})"))
  (should (cljbang-test--eval "(= {:a [1]} {:a [1]})"))
  (should (cljbang-test--eval "(= #{1 2} #{2 1})"))
  (should-not (cljbang-test--eval "(= {:a 1} {:a 2})"))
  (should-not (cljbang-test--eval "(= {:a 1} {:a 1 :b 2})"))
  (should-not (cljbang-test--eval "(= #{1 2} #{1 3})")))

(ert-deftest cljbang-test-equality-spans-sequential-types ()
  (should (cljbang-test--eval "(= [1 2] [1 2])"))
  (should (cljbang-test--eval "(= [1 2] (list 1 2))"))
  (should-not (cljbang-test--eval "(= [1 2] [1 3])"))
  ;; nil is not an empty sequence, as in Clojure
  (should-not (cljbang-test--eval "(= [] nil)")))

(ert-deftest cljbang-test-equality-is-variadic ()
  (should (cljbang-test--eval "(= 1 1 1)"))
  (should-not (cljbang-test--eval "(= 1 1 2)"))
  (should (cljbang-test--eval "(= {:a 1} {:a 1} {:a 1})")))

(ert-deftest cljbang-test-not-equal ()
  (should-not (cljbang-test--eval "(not= {:a 1} {:a 1})"))
  (should (cljbang-test--eval "(not= {:a 1} {:a 2})")))

(ert-deftest cljbang-test-count ()
  (should (= 3 (cljbang-test--eval "(count [1 2 3])")))
  (should (= 2 (cljbang-test--eval "(count {:a 1 :b 2})")))
  (should (= 0 (cljbang-test--eval "(count nil)"))))

(ert-deftest cljbang-test-str ()
  (should (equal "ab" (cljbang-test--eval "(str \"a\" \"b\")")))
  (should (equal "" (cljbang-test--eval "(str nil)")))
  (should (equal "1" (cljbang-test--eval "(str 1)"))))

(ert-deftest cljbang-test-str-quotes-nested-strings ()
  "Clojure's str leaves a top-level string bare and quotes nested ones."
  (should (equal "a" (cljbang-test--eval "(str \"a\")")))
  (should (equal "[1 \"b\"]" (cljbang-test--eval "(str [1 \"b\"])")))
  (should (equal "{:a \"x\"}" (cljbang-test--eval "(str {:a \"x\"})"))))

(ert-deftest cljbang-test-pr-str ()
  (should (equal "\"a\"" (cljbang-test--eval "(pr-str \"a\")")))
  (should (equal "[1 \"b\" :c]" (cljbang-test--eval "(pr-str [1 \"b\" :c])")))
  (should (equal "{:a \"x\"}" (cljbang-test--eval "(pr-str {:a \"x\"})")))
  (should (equal "nil" (cljbang-test--eval "(pr-str nil)")))
  (should (equal "1 2" (cljbang-test--eval "(pr-str 1 2)"))))

(ert-deftest cljbang-test-inline-eval-prints-readably ()
  "The overlay is REPL output, so a string shows its quotes."
  (with-temp-buffer
    (setq-local cljbang-whole-buffer t)
    (insert "[1 \"b\" :c]")
    (cljbang-eval-last-sexp)
    (should (string-match-p "\\[1 \"b\" :c\\]"
                            (overlay-get (car cljbang--result-overlays)
                                         'after-string)))))


;;; Sequence and map functions

(ert-deftest cljbang-test-seq-functions ()
  (should (equal [1 2] (cljbang-test--eval "(into [] [1 2])")))
  (should (equal [1 2 3] (cljbang-test--eval "(into [1] (list 2 3))")))
  (should (equal [2 3] (cljbang-test--eval "(mapv inc [1 2])")))
  (should (equal '(1 1 2 2) (cljbang-test--eval "(mapcat (fn [x] [x x]) [1 2])")))
  (should (equal '(1 2) (cljbang-test--eval "(take 2 [1 2 3])")))
  (should (equal '(2 3) (cljbang-test--eval "(drop 1 [1 2 3])")))
  (should (equal '(1 3) (cljbang-test--eval "(take-while odd? [1 3 2])")))
  (should (equal '(1 2) (cljbang-test--eval "(distinct [1 1 2])")))
  (should (equal [1 2] (cljbang-test--eval "(vec (list 1 2))"))))

(ert-deftest cljbang-test-range ()
  (should (equal '(0 1 2) (cljbang-test--eval "(range 3)")))
  (should (equal '(1 2 3) (cljbang-test--eval "(range 1 4)")))
  (should (equal '(4 3 2) (cljbang-test--eval "(range 4 1 -1)")))
  (should (null (cljbang-test--eval "(range 0)"))))

(ert-deftest cljbang-test-seq-is-nil-when-empty ()
  (should (null (cljbang-test--eval "(seq [])")))
  (should (equal '(1) (cljbang-test--eval "(seq [1])")))
  (should (cljbang-test--eval "(empty? [])"))
  (should (cljbang-test--eval "(empty? {})"))
  (should-not (cljbang-test--eval "(empty? [1])")))

(ert-deftest cljbang-test-apply-takes-a-collection-last ()
  "Elisp apply needs a list, Clojure's takes any collection."
  (should (= 6 (cljbang-test--eval "(apply + [1 2 3])")))
  (should (= 6 (cljbang-test--eval "(apply + 1 [2 3])"))))

(ert-deftest cljbang-test-some-and-every ()
  (should (cljbang-test--eval "(some odd? [2 3])"))
  (should (null (cljbang-test--eval "(some odd? [2 4])")))
  (should (= 3 (cljbang-test--eval "(some #{3} [2 3])")))
  (should (cljbang-test--eval "(every? odd? [1 3])"))
  (should-not (cljbang-test--eval "(every? odd? [1 2])")))

(ert-deftest cljbang-test-sort-by ()
  (should (equal '("a" "aaa") (cljbang-test--eval "(sort-by count [\"aaa\" \"a\"])")))
  (should (equal '("aaa" "a") (cljbang-test--eval "(sort-by count > [\"a\" \"aaa\"])"))))

(ert-deftest cljbang-test-map-functions ()
  (should (equal '(:a) (cljbang-test--eval "(keys {:a 1})")))
  (should (equal '(1) (cljbang-test--eval "(vals {:a 1})")))
  (should (= 2 (cljbang-test--eval "(get (merge {:a 1} {:a 2}) :a)")))
  (should (= 2 (cljbang-test--eval "(get (update {:a 1} :a inc) :a)")))
  (should (null (cljbang-test--eval "(get (dissoc {:a 1} :a) :a)")))
  (should (= 1 (cljbang-test--eval "(count (select-keys {:a 1 :b 2} [:a]))"))))

(ert-deftest cljbang-test-nested-map-access ()
  (should (= 1 (cljbang-test--eval "(get-in {:a {:b 1}} [:a :b])")))
  (should (eq :d (cljbang-test--eval "(get-in {:a 1} [:x] :d)")))
  (should (= 1 (cljbang-test--eval "(get-in (assoc-in {} [:a :b] 1) [:a :b])")))
  (should (= 2 (cljbang-test--eval "(get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b])"))))

(ert-deftest cljbang-test-keys-and-vals-read-alists ()
  "An alist reads as a map, so its keys and values do too."
  (should (equal '(:a) (cljbang-test--eval "(keys '((:a . 1)))")))
  (should (equal '(1) (cljbang-test--eval "(vals '((:a . 1)))"))))

(ert-deftest cljbang-test-into-refuses-an-ambiguous-pair ()
  "A map and a set are the same type, so a pair onto one is undecidable."
  (should-error (cljbang-test--eval "(into {} [[:a 1]])"))
  (should (= 2 (cljbang-test--eval "(count (into #{} [1 2]))"))))

(ert-deftest cljbang-test-function-functions ()
  (should (= 3 (cljbang-test--eval "((partial + 1) 2)")))
  (should (= 3 (cljbang-test--eval "((comp inc inc) 1)")))
  (should (null (cljbang-test--eval "((complement odd?) 1)")))
  (should (eq :k (cljbang-test--eval "((constantly :k) 9)"))))

(ert-deftest cljbang-test-predicates ()
  (should (cljbang-test--eval "(map? {})"))
  (should (cljbang-test--eval "(vector? [1])"))
  (should (cljbang-test--eval "(nil? nil)"))
  (should (cljbang-test--eval "(some? 1)"))
  (should (cljbang-test--eval "(string? \"a\")"))
  (should (cljbang-test--eval "(keyword? :a)")))

(ert-deftest cljbang-test-symbol-is-not-a-keyword ()
  "A keyword is a symbol in elisp, but not in Clojure."
  (should (cljbang-test--eval "(symbol? 'a)"))
  (should-not (cljbang-test--eval "(symbol? :a)"))
  (should (eq :a (cljbang-test--eval "(keyword \"a\")")))
  (should (eq 'a (cljbang-test--eval "(symbol \"a\")"))))

;;; Atoms

(ert-deftest cljbang-test-atom ()
  (should (= 1 (cljbang-test--eval "(let [a (atom 0)] (swap! a inc) (deref a))")))
  (should (= 5 (cljbang-test--eval "(let [a (atom 0)] (reset! a 5) (deref a))")))
  (should (= 2 (cljbang-test--eval
                "(let [a (atom {:n 1})] (swap! a update :n inc) (get (deref a) :n))"))))

(ert-deftest cljbang-test-deref-reader-syntax ()
  "@x reads as a deref, and only at the start of a token."
  (should (= 5 (cljbang-test--eval "(let [a (atom 5)] @a)")))
  (should (= 6 (cljbang-test--eval "(let [a (atom 5)] (inc @a))")))
  (should (equal "a@b" (cljbang-test--eval "(str \"a@b\")"))))

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
  (cljbang-load-file (cljbang-test--example "literals.clj"))
  (should (eq :bob (cljbang-test--eval "(literals/winner literals/scores)")))
  (cljbang-load-file (cljbang-test--example "fast.clj"))
  (should (= 55 (cljbang-test--eval "(fast/fib 10)"))))

(ert-deftest cljbang-test-load-file-restores-ns ()
  "An (ns ...) inside a loaded file does not leak into the caller."
  (let ((before (cljbang--current-ns)))
    (cljbang-load-file (cljbang-test--example "fast.clj"))
    (should (equal before (cljbang--current-ns)))))

(ert-deftest cljbang-test-aliases-belong-to-their-namespace ()
  "An alias one file declares is not visible in another, as in Clojure."
  (let ((dir (make-temp-file "cljbang-ns" t)))
    (unwind-protect
        (let ((lib (expand-file-name "lib" dir))
              (cljbang-load-path (list dir)))
          (make-directory lib)
          (write-region "(ns lib.helper)\n(defn greet [x] (str \"hi \" x))\n"
                        nil (expand-file-name "helper.clj" lib) nil 'quiet)
          (write-region "(ns aliasa (:require [lib.helper :as h]))\n(defn use-it [] (h/greet \"a\"))\n"
                        nil (expand-file-name "aliasa.clj" dir) nil 'quiet)
          (write-region "(ns aliasb)\n(defn sneaky [] (h/greet \"b\"))\n"
                        nil (expand-file-name "aliasb.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "aliasa.clj" dir))
          (should (equal "hi a" (aliasa-use-it)))
          (should (equal "lib.helper" (cdr (assq 'h (cljbang--ns-aliases "aliasa")))))
          ;; b never required it, so h is not an alias there
          (should (null (cljbang--ns-aliases "aliasb")))
          (let ((cljbang-warn-unresolved nil))
            (cljbang-load-file (expand-file-name "aliasb.clj" dir)))
          (should-error (aliasb-sneaky)))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-a-cached-load-registers-its-aliases ()
  "A warm load must leave the same aliases behind as a cold one."
  (let ((dir (make-temp-file "cljbang-ns" t)))
    (unwind-protect
        (let ((lib (expand-file-name "lib" dir))
              (cljbang-load-path (list dir)))
          (make-directory lib)
          (write-region "(ns lib.cached)\n(defn greet [x] (str \"hi \" x))\n"
                        nil (expand-file-name "cached.clj" lib) nil 'quiet)
          (write-region "(ns warmns (:require [lib.cached :as c]))\n(defn use-it [] (c/greet \"w\"))\n"
                        nil (expand-file-name "warmns.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "warmns.clj" dir))
          (should (equal "hi w" (warmns-use-it)))
          ;; forget the aliases, then load again from the cache
          (remhash "warmns" cljbang--ns-state)
          (cljbang-load-file (expand-file-name "warmns.clj" dir))
          (should (equal "lib.cached" (cdr (assq 'c (cljbang--ns-aliases "warmns"))))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-vars-belong-to-their-namespace ()
  (cljbang-test--eval "(ns nsone) (defn only-here [] :x)")
  (cljbang-test--eval "(ns nstwo)")
  (cljbang--set-current-ns "nsone")
  (should (eq 'nsone-only-here (cljbang--ns-resolve 'only-here)))
  (cljbang--set-current-ns "nstwo")
  (should (null (cljbang--ns-resolve 'only-here)))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-ns-state-is-one-table ()
  "The current namespace and the per-namespace state share one map."
  (cljbang-test--eval "(ns nsthree) (defn thing [] :x)")
  (should (equal "nsthree" (gethash :current cljbang--ns-state)))
  (should (equal "nsthree" (cljbang--current-ns)))
  (should (gethash "thing" (plist-get (gethash "nsthree" cljbang--ns-state) :vars)))
  (cljbang--set-current-ns nil))

;;; Compiling a file to a cache

(ert-deftest cljbang-test-compile-file-round-trip ()
  "A cached load defines the same things, without running the compiler."
  (let* ((dir (make-temp-file "cljbang-cache" t))
         (f (expand-file-name "cached_conf.clj" dir)))
    (unwind-protect
        (progn
          (write-region "(ns cachedconf)\n(defn greet [x] (str \"hi \" x))\n(def answer 42)\n"
                        nil f nil 'quiet)
          (cljbang-load-file f)
          (should (file-exists-p (cljbang--cache-file f)))
          (should (equal "hi you" (cachedconf-greet "you")))
          (should (= 42 cachedconf-answer))
          ;; again, this time from the cache
          (should (cljbang-load-file f))
          (should (equal "hi you" (cachedconf-greet "you"))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-cache-rebuilds-when-source-changes ()
  (let* ((dir (make-temp-file "cljbang-cache" t))
         (f (expand-file-name "stale.clj" dir)))
    (unwind-protect
        (progn
          (write-region "(defn stale-one [] 1)\n" nil f nil 'quiet)
          (cljbang-load-file f)
          (should (= 1 (stale-one)))
          ;; the cache must look older than the source
          (set-file-times (cljbang--cache-file f) (time-subtract (current-time) 10))
          (write-region "(defn stale-one [] 2)\n" nil f nil 'quiet)
          (cljbang-load-file f)
          (should (= 2 (stale-one))))
      (delete-directory dir t))))

(ert-deftest cljbang-test-cache-is-keyed-on-versions ()
  "Upgrading Emacs or cljbang must miss the old cache, not load it."
  (let ((name (cljbang--cache-file "/tmp/x.clj")))
    (should (string-suffix-p (format ".%d-%s.elc" emacs-major-version cljbang-version)
                             name))
    (let ((cljbang-version "9.9.9"))
      (should-not (equal name (cljbang--cache-file "/tmp/x.clj"))))))

(ert-deftest cljbang-test-cached-file-registers-its-macros ()
  "A macro has to survive a load that never runs the compiler."
  (let* ((dir (make-temp-file "cljbang-cache" t))
         (f (expand-file-name "mac.clj" dir)))
    (unwind-protect
        (progn
          (write-region "(ns cachedmac)\n(defmacro dbl [x] (list '* x 2))\n" nil f nil 'quiet)
          (cljbang-load-file f)
          (remhash "dbl" (cljbang--ns-macro-table "cachedmac"))
          (load (cljbang--cache-file f) nil t)   ; only the cache
          (cljbang--set-current-ns nil)
          (should (= 42 (cljbang-test--eval "(cachedmac/dbl 21)"))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))


(ert-deftest cljbang-test-a-cached-file-uses-a-macro-from-another ()
  "The use is expanded when the file is compiled, and the macro is
registered again when the cache loads."
  (let ((dir (make-temp-file "cljbang-aot" t)))
    (unwind-protect
        (let ((cljbang-load-path (list dir)))
          (write-region (concat "(ns aotlib)\n"
                                "(defmacro dbl [x] `(* ~x 2))\n"
                                "(defn plain [x] (dbl x))\n")
                        nil (expand-file-name "aotlib.clj" dir) nil 'quiet)
          (write-region (concat "(ns aotuser (:require [aotlib :as a]))\n"
                                "(defn go [] [(a/dbl 21) (aotlib/plain 5)])\n")
                        nil (expand-file-name "aotuser.clj" dir) nil 'quiet)
          (cljbang-load-file (expand-file-name "aotlib.clj" dir))
          (cljbang--set-current-ns nil)
          (cljbang-load-file (expand-file-name "aotuser.clj" dir))
          (should (equal [42 10] (aotuser-go)))
          ;; forget the macro, then load only the caches
          (remhash "dbl" (cljbang--ns-macro-table "aotlib"))
          (load (cljbang--cache-file (expand-file-name "aotlib.clj" dir)) nil t)
          (load (cljbang--cache-file (expand-file-name "aotuser.clj" dir)) nil t)
          (cljbang--set-current-ns nil)
          (should (equal [42 10] (aotuser-go)))
          (should (gethash "dbl" (cljbang--ns-macro-table "aotlib"))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-clojure-string ()
  "Checked against Clojure, including the argument orders elisp reverses."
  (should (cljbang-test--eval "(str/includes? \"hello\" \"ell\")"))
  (should-not (cljbang-test--eval "(str/includes? \"hello\" \"z\")"))
  (should (cljbang-test--eval "(str/starts-with? \"hello\" \"he\")"))
  (should (cljbang-test--eval "(str/ends-with? \"hello\" \"lo\")"))
  (should (= 2 (cljbang-test--eval "(str/index-of \"hello\" \"l\")")))
  ;; nil when absent, not -1
  (should-not (cljbang-test--eval "(str/index-of \"hello\" \"z\")"))
  (should-not (cljbang-test--eval "(str/index-of \"hello\" \"l\" 4)"))
  (should (= 3 (cljbang-test--eval "(str/last-index-of \"hello\" \"l\")")))
  (should (equal "a  " (cljbang-test--eval "(str/triml \"  a  \")")))
  (should (equal "  a" (cljbang-test--eval "(str/trimr \"  a  \")")))
  (should (equal "a" (cljbang-test--eval "(str/trim-newline \"a\\n\")")))
  (should (equal ["a" "b"] (cljbang-test--eval "(str/split-lines \"a\\nb\")")))
  (should (equal "cba" (cljbang-test--eval "(str/reverse \"abc\")"))))

;;; Namespaces

(ert-deftest cljbang-test-ns-interns-munged-names ()
  "(ns foo) makes defn intern foo-name, callable from elisp."
  (cljbang-test--eval "(ns nstest) (defn triple [x] (* 3 x))")
  (should (fboundp 'nstest-triple))
  (should (= 9 (nstest-triple 3)))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-defn-private-uses-double-dash ()
  "Elisp spells internal names with two dashes, which is Clojure's defn-."
  (cljbang-test--eval "(ns privtest) (defn pub [x] x) (defn- priv [x] x)")
  (should (fboundp 'privtest-pub))
  (should (fboundp 'privtest--priv))
  (should-not (fboundp 'privtest--pub))
  (should-not (fboundp 'privtest-priv))
  (should (= 1 (cljbang-test--eval "(priv 1)")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-qualified-reaches-public-elisp ()
  "lib/thing must reach lib-thing, the public elisp API convention."
  (should (eq 'magit-status (cljbang--qualified 'magit/status)))
  (should (eq 'my-deep-ns-f (cljbang--qualified 'my.deep.ns/f))))

(ert-deftest cljbang-test-ns-qualified-call ()
  (cljbang-test--eval "(ns nsq) (defn dbl [x] (* 2 x))")
  (cljbang--set-current-ns nil)
  (should (= 8 (cljbang-test--eval "(nsq/dbl 4)"))))

(ert-deftest cljbang-test-ns-alias ()
  (cljbang-test--eval "(ns aliased (:require [clojure.string :as str]))")
  (should (equal "a,b" (cljbang-test--eval "(str/join \",\" [\"a\" \"b\"])")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-ns->file ()
  "Namespaces map to file names the way Clojure spells them."
  (should (equal "lib/b.clj" (cljbang--ns->file "lib.b")))
  (should (equal "lib/some_thing.clj" (cljbang--ns->file "lib.some-thing"))))

(defun cljbang-test--clear-caches ()
  "Remove compiled caches under the fixtures.
They outlive a test run, so a cache built by an older compiler would
otherwise be picked up by the next one."
  (dolist (f (directory-files-recursively
              (expand-file-name "test/requires" cljbang-test--root)
              "\\.elc\\'"))
    (delete-file f)))

(ert-deftest cljbang-test-require-loads-clj-file ()
  "A :require pulls in the .clj file it names, without loading it first."
  (cljbang-test--clear-caches)
  (clrhash cljbang--loaded-ns)
  (let ((dir (expand-file-name "test/requires/" cljbang-test--root)))
    (cljbang-load-file (expand-file-name "app/a.clj" dir))
    (should (fboundp 'lib-b-hello))
    (should (equal "hello from b: a" (app-a-run))))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-cached-file-still-loads-its-requires ()
  "A require runs at compile time, so the cache has to carry it too."
  (let* ((dir (make-temp-file "cljbang-req" t))
         (lib (expand-file-name "lib/c.clj" dir))
         (app (expand-file-name "useslib.clj" dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "lib" dir) t)
          (write-region "(ns lib.c)\n(defn from-c [] :c)\n" nil lib nil 'quiet)
          (write-region "(ns uses (:require [lib.c :as c]))\n(defn run [] (c/from-c))\n"
                        nil app nil 'quiet)
          (cljbang-load-file app)               ; cold, builds the cache
          (should (eq :c (uses-run)))
          ;; forget everything the compiler learned, then load only the cache
          (clrhash cljbang--loaded-ns)
          (fmakunbound 'lib-c-from-c)
          (cljbang-load-file app)
          (should (fboundp 'lib-c-from-c))
          (should (eq :c (uses-run))))
      (delete-directory dir t)
      (cljbang--set-current-ns nil))))

(ert-deftest cljbang-test-require-form-without-ns ()
  "(require '[lib :as l]) works in a file that has no ns form."
  (cljbang-test--clear-caches)
  (clrhash cljbang--loaded-ns)
  (let ((cljbang-load-path (list (expand-file-name "test/requires" cljbang-test--root))))
    (should (cljbang-test--eval "(require '[lib.b :as lb]) (lb/hello \"x\")")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-cljbang-require-from-elisp ()
  (cljbang-test--clear-caches)
  (clrhash cljbang--loaded-ns)
  (let ((cljbang-load-path (list (expand-file-name "test/requires" cljbang-test--root))))
    (should (equal "lib.b" (cljbang-require 'lib.b)))
    (should (fboundp 'lib-b-hello)))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-require-loads-elisp-feature ()
  (clrhash cljbang--loaded-ns)
  (cljbang-test--eval "(ns reqfeat (:require [subr-x :as sx]))")
  (should (featurep 'subr-x))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-require-allows-builtin-prefixes ()
  "Emacs built-ins have prefixes that name no feature, so string- is fine."
  (clrhash cljbang--loaded-ns)
  (should (cljbang-test--eval "(ns reqpfx (:require [string :as s])) :ok"))
  (should (equal "hi" (cljbang-test--eval "(s/trim \"  hi  \")")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-require-rejects-typos ()
  "Nothing loadable and nothing defined under the prefix means a mistake."
  (clrhash cljbang--loaded-ns)
  (should-error (cljbang-test--eval "(ns reqmiss (:require [no-such-package-xyz :as n]))"))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-require-skips-builtin-namespaces ()
  "clojure.string is cljbang's own, not an elisp feature to load."
  (clrhash cljbang--loaded-ns)
  (should (equal "a,b" (cljbang-test--eval
                        "(ns reqstr (:require [clojure.string :as str])) (str/join \",\" [\"a\" \"b\"])")))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-as-alias-does-not-load ()
  (clrhash cljbang--loaded-ns)
  (cljbang-test--eval "(ns reqnoload (:require [lib.b :as-alias bb]))")
  (should-not (gethash "lib.b" cljbang--loaded-ns))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-require-cycle-terminates ()
  "cyc.a and cyc.b require each other, so the guard has to break the loop."
  (cljbang-test--clear-caches)
  (clrhash cljbang--loaded-ns)
  (let ((dir (expand-file-name "test/requires/" cljbang-test--root)))
    (should (cljbang-load-file (expand-file-name "cyc/a.clj" dir))))
  ;; proves the cycle was actually traversed, not silently skipped
  (should (fboundp 'cyc-b-from-b))
  (should (fboundp 'cyc-a-from-a))
  (cljbang--set-current-ns nil))

(ert-deftest cljbang-test-as-alias-is-accepted ()
  "el/ resolves to the host whatever an alias claims."
  (cljbang-test--eval "(ns withalias (:require [cljbang.el :as-alias el]))")
  (should (equal "AB" (cljbang-test--eval "(el/upcase \"ab\")")))
  (cljbang--set-current-ns nil))


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
    (should (fboundp 'buffns-quad))
    (should (= 12 (buffns-quad 3)))))

(provide 'cljbang-test)
;;; cljbang-test.el ends here
