;;; cljbang-core.el --- Runtime for cljbang -*- lexical-binding: t; -*-

;;; Commentary:

;; The Clojure core that compiled cljbang code calls at run time.  A
;; byte-compiled file needs this and not the compiler, so it is kept
;; separate and requires nothing of cljbang.el.

;;; Code:

(require 'cl-lib)
(require 'seq)
;; string-join, if-let* and when-let* live here before Emacs 29
(require 'subr-x)
;; map-elt reads alists and plists as well as hash tables
(require 'map)

(defun cljbang-first (coll)
  (if (seq-empty-p coll) nil (seq-elt coll 0)))

(defun cljbang-rest (coll)
  (seq-into (seq-drop coll 1) 'list))

(defun cljbang-second (coll)
  (cljbang-first (cljbang-rest coll)))

;; a set, map or keyword can be passed where a function is expected, as
;; in (filter #{1 3} xs).  cljbang--fn resolves that once per call rather
;; than once per element, so the ordinary case stays a bare funcall.

(defun cljbang--fn (f)
  "F as something funcall can take, wrapping a set, map or keyword."
  (if (functionp f) f (lambda (&rest args) (apply #'cljbang--invoke f args))))

(defun cljbang-map (f coll)
  (mapcar (cljbang--fn f) (seq-into coll 'list)))

(defun cljbang-filter (pred coll)
  (seq-filter (cljbang--fn pred) (seq-into coll 'list)))

(defun cljbang-reduce (f init coll)
  (seq-reduce (cljbang--fn f) (seq-into coll 'list) init))

(defun cljbang-count (coll)
  (if (hash-table-p coll) (hash-table-count coll) (seq-length coll)))

(defun cljbang-conj (coll x)
  (cond ((vectorp coll) (vconcat coll (vector x)))
        ((hash-table-p coll)
         (let ((h (copy-hash-table coll))) (puthash x x h) h))
        (t (cons x coll))))

(defun cljbang-re-pattern (pattern)
  "A regex over PATTERN.  The syntax is elisp's, not Java's, as the host wins."
  (record 'cljbang-regex pattern))

(defun cljbang--regex-p (x)
  (and (recordp x) (eq (aref x 0) 'cljbang-regex)))

(defun cljbang--regex-string (x)
  (if (cljbang--regex-p x) (aref x 1) x))

(defun cljbang--match (s)
  "The last match in S: the string when there are no groups, else a vector."
  (let ((groups (1- (/ (length (match-data)) 2))))
    (if (zerop groups)
        (match-string 0 s)
      (apply #'vector
             (mapcar (lambda (i) (match-string i s))
                     (number-sequence 0 groups))))))

(defun cljbang-re-find (re s)
  (when (string-match (cljbang--regex-string re) s)
    (cljbang--match s)))

(defun cljbang-re-matches (re s)
  "Like re-find, but only when RE matches all of S."
  (let ((p (cljbang--regex-string re)))
    (when (and (string-match p s)
               (= 0 (match-beginning 0))
               (= (length s) (match-end 0)))
      (cljbang--match s))))

(defun cljbang-re-seq (re s)
  (let ((p (cljbang--regex-string re))
        (i 0)
        acc)
    (while (and (<= i (length s)) (string-match p s i))
      (push (match-string 0 s) acc)
      ;; an empty match would not advance on its own
      (setq i (if (= (match-end 0) (match-beginning 0))
                  (1+ (match-end 0))
                (match-end 0))))
    (nreverse acc)))

(defun cljbang-hash-map (&rest kvs)
  (let ((h (make-hash-table :test #'equal)))
    (while kvs (puthash (pop kvs) (pop kvs) h))
    h))

(defun cljbang-subs (s start &optional end)
  "Substring of S from START to END.
Elisp's substring counts a negative index from the end of the string;
Clojure's subs treats it as out of range, so reject it."
  (when (or (< start 0) (and end (< end 0)))
    (error "String index out of range: %d" (if (< start 0) start end)))
  (substring s start end))

(defun cljbang-nth (coll i &rest not-found)
  "Element I of COLL.  Out of range is an error unless NOT-FOUND is given."
  (cond ((and coll (>= i 0) (< i (cljbang-count coll))) (seq-elt coll i))
        (not-found (car not-found))
        ((null coll) nil)
        (t (error "Index out of bounds: %d" i))))

(defun cljbang-name (x)
  "Name of keyword, symbol or string X, without colon or namespace."
  (cond ((stringp x) x)
        ;; a keyword is a symbol here, so both lose the colon then the ns
        ((symbolp x)
         (let* ((s (symbol-name x))
                (s (if (string-prefix-p ":" s) (substring s 1) s))
                (i (string-search "/" s)))
           (if i (substring s (1+ i)) s)))
        (t (error "cljbang: cannot take name of %S" x))))

(defun cljbang-hash-set (&rest xs)
  "Set of XS, a hash table mapping each element to itself."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (x xs h) (puthash x x h))))

(defun cljbang-get (m k &optional default)
  "Look K up in M, which may be a map, a vector, or an elisp alist or plist.
Reading native elisp data matters because destructuring goes through here."
  (cond ((hash-table-p m) (gethash k m default))
        ((vectorp m) (if (and (integerp k) (>= k 0) (< k (length m)))
                         (aref m k)
                       default))
        ((null m) default)
        ;; a key present with a nil value is not the same as absent, so
        ;; ask whether the entry exists rather than what it returned
        ((consp (car m))
         (let ((cell (assoc k m)))
           (if cell (cdr cell) default)))
        ((consp m)
         (let ((tail (plist-member m k)))
           (if tail (cadr tail) default)))
        (t default)))

(defun cljbang--invoke (f &rest args)
  "Call F as Clojure does.
Sets, maps and vectors look their argument up.  A keyword looks itself
up in its argument.  Checking functionp first keeps byte-code objects,
which are vector-like, out of the lookup branches."
  (cond ((functionp f) (apply f args))
        ((or (hash-table-p f) (vectorp f)) (apply #'cljbang-get f args))
        ((keywordp f) (apply #'cljbang-get (car args) f (cdr args)))
        (t (apply f args))))

(defun cljbang-contains? (coll k)
  "Whether COLL has key K.  For a vector K is an index, as in Clojure."
  (cond ((hash-table-p coll)
         (not (eq 'cljbang--absent (gethash k coll 'cljbang--absent))))
        ((vectorp coll) (and (integerp k) (>= k 0) (< k (length coll))))
        ((null coll) nil)
        ((consp coll) (and (map-elt coll k) t))
        (t nil)))

(defun cljbang-assoc (m k v)
  (let ((h (copy-hash-table m)))
    (puthash k v h)
    h))

;; Elisp's equal compares hash tables by identity and keeps vectors and
;; lists apart.  Clojure's = is structural, spans the sequential types,
;; and takes any number of arguments.

(defun cljbang--sequential-p (x)
  "Whether X is one of Clojure's sequential collections.
Strings are not, and nil is not, so (= [] nil) stays false as in Clojure."
  (or (vectorp x) (and (consp x) (proper-list-p x))))

(defun cljbang--equal (a b)
  (cond
   ((and (hash-table-p a) (hash-table-p b))
    (and (= (hash-table-count a) (hash-table-count b))
         (catch 'cljbang--unequal
           (maphash (lambda (k v)
                      (let ((bv (gethash k b 'cljbang--absent)))
                        (when (or (eq bv 'cljbang--absent)
                                  (not (cljbang--equal v bv)))
                          (throw 'cljbang--unequal nil))))
                    a)
           t)))
   ((or (hash-table-p a) (hash-table-p b)) nil)
   ((and (cljbang--sequential-p a) (cljbang--sequential-p b))
    (let ((la (append a nil))
          (lb (append b nil)))
      (and (= (length la) (length lb))
           (cl-every #'cljbang--equal la lb))))
   ((or (cljbang--sequential-p a) (cljbang--sequential-p b)) nil)
   (t (equal a b))))

(defun cljbang-= (a b &rest more)
  "Whether A, B and MORE are equal, structurally, as in Clojure."
  (and (cljbang--equal a b)
       (or (null more)
           (apply #'cljbang-= b more))))

(defun cljbang--print (x readably)
  "Print X.  READABLY quotes strings, the difference between pr-str and str."
  (let ((rec (lambda (v) (cljbang--print v readably))))
    (cond ((null x) "nil")
          ((eq x t) "true")
          ((stringp x) (if readably (prin1-to-string x) x))
          ((hash-table-p x)
           (let (pairs)
             (maphash (lambda (k v)
                        (push (concat (funcall rec k) " " (funcall rec v)) pairs))
                      x)
             (concat "{" (string-join (nreverse pairs) ", ") "}")))
          ((vectorp x)
           (concat "[" (mapconcat rec x " ") "]"))
          ((proper-list-p x)
           (concat "(" (mapconcat rec x " ") ")"))
          (t (format "%s" x)))))

(defun cljbang-pr-str (&rest xs)
  "Print XS readably, so a string comes back with its quotes."
  (mapconcat (lambda (x) (cljbang--print x t)) xs " "))

(defun cljbang-str (&rest xs)
  "Concatenate XS.  A string argument is itself, but one nested in a
collection keeps its quotes, which is what Clojure's str does."
  (mapconcat (lambda (x)
               (cond ((null x) "")
                     ((stringp x) x)
                     (t (cljbang--print x t))))
             xs ""))

(defun cljbang-println (&rest xs)
  (princ (mapconcat (lambda (x) (cljbang--print x nil)) xs " "))
  (princ "\n")
  nil)

(defun cljbang-prn (&rest xs)
  "Like println, but readably, so a string keeps its quotes."
  (princ (apply #'cljbang-pr-str xs))
  (princ "\n")
  nil)

(defun cljbang-not= (&rest args) (not (apply #'cljbang-= args)))


(defun cljbang--resolve (sym)
  "Lisp-1 view over elisp's split namespaces: var first, then function."
  (cond ((boundp sym) (symbol-value sym))
        ((fboundp sym) (symbol-function sym))
        (t (error "Unable to resolve symbol: %s" sym))))

(provide 'cljbang-core)
;;; cljbang-core.el ends here
