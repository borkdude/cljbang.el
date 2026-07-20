;;; test-clj2el.el --- headless test for clj2el-core -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "parseclj" (file-name-directory load-file-name)))
(load (expand-file-name "clj2el-core.el" (file-name-directory load-file-name)) nil t)

(defvar clj-src "
(defn square [x] (* x x))
(defn sum-squares [xs] (reduce + 0 (map square xs)))
(println \"sum of squares [1 2 3 4]:\" (sum-squares [1 2 3 4]))
(def greeting (str \"Hello, \" \"Clojure-on-elisp!\"))
(println greeting)
(println \"threaded ->:\" (-> 2 square square))
(println \"threaded ->>:\" (->> [1 2 3] (map inc) (reduce + 0)))
(let [m {:a 1 :b 2}
      a (get m :a)]
  (println \"map literal:\" m)
  (println \"(get m :a):\" a)
  (println \"assoc:\" (assoc m :c 3)))
(println \"odds:\" (filter odd? [1 2 3 4 5]))
(println \"anon fn:\" (map (fn [x] (+ x 10)) [1 2 3]))
(println \"if:\" (if (< 1 2) \"yes\" \"no\"))
(defn my-apply [f x] (f x))
(println \"local fn param:\" (my-apply (fn [x] (* x 100)) 7))
(println \"conj vec:\" (conj [1 2] 3))
(println \"count:\" (count [10 20 30]) (count {:a 1}))
")

(clj2el-eval-string clj-src)

;; In-memory byte-compilation of a Clojure-defined function: no source
;; file exists for `sum-squares' anywhere -- it was born as an elisp
;; form and now becomes bytecode.
(byte-compile 'square)
(byte-compile 'sum-squares)
(princ (format "byte-compiled? %s\n"
               (byte-code-function-p (symbol-function 'sum-squares))))
(clj2el-eval-string "(println \"post-compile call:\" (sum-squares [5 6 7]))")

;; Redefinition against the live image: the REPL story.
(clj2el-eval-string "(defn square [x] \"not squaring anymore\")")
(clj2el-eval-string "(println \"redefined:\" (square 3))")
