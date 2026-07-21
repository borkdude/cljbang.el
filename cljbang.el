;;; cljbang.el --- Clojure that runs as Emacs Lisp -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Homepage: https://github.com/borkdude/cljbang
;; Keywords: languages, lisp

;;; Commentary:

;; Reads Clojure source with the elisp reader, compiles Clojure special
;; forms to elisp forms, and evaluates them in the running Emacs.  No
;; elisp source text is ever printed or re-read.
;;
;; Clojure lives in an elisp buffer inside the clj! macro, in a .clj file
;; loaded with `cljbang-load-file', or is evaluated form by form with
;; `cljbang-eval-last-sexp'.
;;
;; Interop is direct: a name cljbang does not define compiles to a plain
;; elisp call.  el/ reaches the host environment explicitly, the way js/
;; does in ClojureScript.

;;; Code:

(require 'cl-lib)
(require 'seq)

;;; Runtime: minimal Clojure core on top of elisp

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
  (cond ((hash-table-p m) (gethash k m default))
        ((vectorp m) (if (< k (length m)) (aref m k) default))
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
        (t nil)))

(defun cljbang-assoc (m k v)
  (let ((h (copy-hash-table m)))
    (puthash k v h)
    h))

(defun cljbang--pr-str (x)
  (cond ((null x) "nil")
        ((eq x t) "true")
        ((stringp x) x)
        ((hash-table-p x)
         (let (pairs)
           (maphash (lambda (k v)
                      (push (concat (cljbang--pr-str k) " " (cljbang--pr-str v)) pairs))
                    x)
           (concat "{" (string-join (nreverse pairs) ", ") "}")))
        ((vectorp x)
         (concat "[" (mapconcat #'cljbang--pr-str x " ") "]"))
        ((proper-list-p x)
         (concat "(" (mapconcat #'cljbang--pr-str x " ") ")"))
        (t (format "%s" x))))

(defun cljbang-str (&rest xs)
  (mapconcat (lambda (x) (if (null x) "" (cljbang--pr-str x))) xs ""))

(defun cljbang-println (&rest xs)
  (princ (mapconcat #'cljbang--pr-str xs " "))
  (princ "\n")
  nil)

;;; Clojure name -> elisp function mapping

(defconst cljbang--core-fns
  ;; / is elisp division: integers, no ratios
  '((+ . +) (- . -) (* . *) (/ . /) (mod . mod)
    (= . equal) (not= . cljbang-not=) (< . <) (> . >) (<= . <=) (>= . >=)
    (inc . 1+) (dec . 1-) (not . not)
    (odd? . cl-oddp) (even? . cl-evenp) (zero? . zerop)
    (first . cljbang-first) (second . cljbang-second) (rest . cljbang-rest)
    (map . cljbang-map) (filter . cljbang-filter) (reduce . cljbang-reduce)
    (str . cljbang-str) (println . cljbang-println)
    (get . cljbang-get) (count . cljbang-count)
    (nth . cljbang-nth) (name . cljbang-name)
    (conj . cljbang-conj) (hash-map . cljbang-hash-map)
    (hash-set . cljbang-hash-set) (contains? . cljbang-contains?)
    (assoc . cljbang-assoc)
    (subs . cljbang-subs)
    (load-file . cljbang-load-file)))

(defun cljbang-not= (a b) (not (equal a b)))

;;; Namespaced symbols: str/join etc.
;;
;; Elisp symbols happily contain `/', so qualified Clojure symbols read
;; as-is.  Aliases map to full namespace names, known vars map to
;; Clojure-semantics wrappers, and anything else munges ns/name to
;; ns-name with dots as dashes.  The munge doubles as interop:
;; (magit/status) calls elisp `magit-status'.

(defconst cljbang--ns-aliases
  '((str . "clojure.string")))

;; Current namespace: (ns foo) makes subsequent defn/def intern munged
;; names (bar -> foo-bar, or foo--bar for defn-), and references to names
;; defined in the current ns resolve to those munged symbols.  The
;; registry is consulted at compile time, so within one clj! block a
;; later form can call an earlier defn even though nothing has been
;; evaluated yet.

(defvar cljbang--current-ns nil
  "Name of the current Clojure namespace (a string), or nil.")

(defvar cljbang--ns-alias-map nil
  "Alist of alias symbol -> namespace name, from (ns ... (:require ... :as ...)).")

(defvar cljbang--ns-vars (make-hash-table :test #'equal)
  "Namespace name -> hash table whose keys are var names defined there.")

(defun cljbang--munge-ns (ns)
  (string-replace "." "-" ns))

;;; Loading what :require names

(defvar cljbang-load-path nil
  "Directories searched for the .clj files named in a :require.
The source root of the file being loaded is searched first.")

(defvar cljbang--loaded-ns (make-hash-table :test #'equal)
  "Namespaces already loaded, so a :require happens once.")

(defvar cljbang--load-file-name nil
  "Absolute name of the file currently loading, if any.")

(defvar cljbang--load-file-dir nil
  "Source root of the file currently loading, searched before the load path.")

(defun cljbang--ns->file (ns)
  "Relative file name for namespace NS, spelled as Clojure spells it."
  (concat (string-replace "-" "_" (string-replace "." "/" ns)) ".clj"))

(defun cljbang--ns-root (ns)
  "Source root implied by the loading file declaring namespace NS.
A namespace path is relative to a root, not to the file's own directory,
so cyc/a.clj declaring cyc.a puts the root above cyc/."
  (when cljbang--load-file-name
    (let ((rel (cljbang--ns->file ns))
          (full cljbang--load-file-name))
      (if (string-suffix-p rel full)
          (substring full 0 (- (length full) (length rel)))
        (file-name-directory full)))))

(defun cljbang--find-ns-file (ns)
  "A readable .clj file for NS on the load path, or nil."
  (let ((rel (cljbang--ns->file ns)))
    (seq-some (lambda (dir)
                (let ((f (expand-file-name rel dir)))
                  (and (file-readable-p f) f)))
              (delq nil (cons cljbang--load-file-dir cljbang-load-path)))))

(defun cljbang--require-ns (ns)
  "Load NS: a .clj file when one is on the load path, else an elisp feature.
A missing elisp feature is not an error, since an alias may name a plain
symbol prefix rather than something loadable."
  (unless (or (gethash ns cljbang--loaded-ns)
              ;; namespaces cljbang implements itself
              (rassoc ns cljbang--ns-aliases))
    ;; marked before loading, so a cycle terminates
    (puthash ns t cljbang--loaded-ns)
    (let ((file (cljbang--find-ns-file ns)))
      (if file
          (cljbang-load-file file)
        (require (intern ns) nil 'noerror)))))

;; Elisp spells the distinction Clojure draws with defn- : one dash for
;; the public API, two for what is internal to a package.  Public is the
;; common case, and it is what ns-qualified interop has to produce to
;; reach names like magit-status.

(defun cljbang--ns-intern (name &optional private)
  "Munged elisp symbol for NAME in the current ns; records the var.
PRIVATE gives the double dash elisp uses for internal names."
  (if cljbang--current-ns
      (let ((vars (or (gethash cljbang--current-ns cljbang--ns-vars)
                      (puthash cljbang--current-ns
                               (make-hash-table :test #'equal)
                               cljbang--ns-vars)))
            (sym (intern (concat (cljbang--munge-ns cljbang--current-ns)
                                 (if private "--" "-")
                                 (symbol-name name)))))
        ;; store the symbol, so resolving does not have to guess which
        ;; spelling this var was defined with
        (puthash (symbol-name name) sym vars)
        sym)
    name))

(defun cljbang--ns-resolve (sym)
  "Munged symbol for SYM when it names a var in the current ns, else nil."
  (when-let* ((ns cljbang--current-ns)
              (vars (gethash ns cljbang--ns-vars)))
    (gethash (symbol-name sym) vars)))

(defun cljbang-string-join (sep-or-coll &optional coll)
  (let ((sep (if coll sep-or-coll ""))
        (xs (seq-into (or coll sep-or-coll) 'list)))
    (mapconcat #'cljbang-str xs sep)))

(defun cljbang-string-split (s re)
  (apply #'vector (split-string s re)))

(defun cljbang-string-replace (s match rep)
  (replace-regexp-in-string (regexp-quote match) rep s))

(defconst cljbang--ns-fns
  '(("clojure.string/join" . cljbang-string-join)
    ("clojure.string/split" . cljbang-string-split)
    ("clojure.string/replace" . cljbang-string-replace)
    ("clojure.string/upper-case" . upcase)
    ("clojure.string/lower-case" . downcase)
    ("clojure.string/capitalize" . capitalize)
    ("clojure.string/trim" . string-trim)
    ("clojure.string/blank?" . string-blank-p)))

;; el/ is the host environment, the way js/ is in ClojureScript: the name
;; after it is an elisp symbol taken verbatim.  It escapes ns munging
;; (el/my/flymake-inline-ov keeps its slash) and the cljbang--core-fns
;; overrides, so elisp's own get, assoc, + ... stay reachable.

(defun cljbang--el-symbol (sym)
  "Elisp symbol named by an el/ qualified SYM, or nil."
  (let ((name (symbol-name sym)))
    (when (and (string-prefix-p "el/" name) (> (length name) 3))
      (intern (substring name 3)))))

(defun cljbang--qualified (sym)
  "Resolve ns-qualified SYM to an elisp function symbol, or nil."
  (let ((name (symbol-name sym)))
    (or (cljbang--el-symbol sym)
        (when (and (> (length name) 1)
                   (string-search "/" name)
                   (not (string-prefix-p "/" name))
                   (not (string-suffix-p "/" name)))
          (let ((parts (split-string name "/")))
            (unless (= (length parts) 2)
              (error "cljbang: %s has more than one /; use el/%s for an elisp name"
                     name name))
            (pcase-let* ((`(,ns ,n) parts)
                         (full (or (cdr (assq (intern ns) cljbang--ns-alias-map))
                                   (cdr (assq (intern ns) cljbang--ns-aliases))
                                   ns)))
              (or (cdr (assoc (concat full "/" n) cljbang--ns-fns))
                  ;; one dash: the public elisp API, so lib/thing reaches
                  ;; lib-thing.  Use el/lib--thing for an internal name.
                  (intern (concat (string-replace "." "-" full) "-" n)))))))))

;;; Compiler: Clojure form -> elisp form

(defun cljbang--compile-body (forms env)
  (mapcar (lambda (f) (cljbang-compile f env)) forms))

;;; Destructuring
;;
;; let bindings and fn params take the same patterns, so both funnel
;; through cljbang--destructure, which flattens one pattern into plain
;; let* pairs.  A pattern binds its value to a gensym and then indexes
;; into it (sequential) or looks keys up in it (associative).  Patterns
;; nest, so the expansion recurses.

(defun cljbang--nth (coll i)
  "Element I of COLL, or nil when out of range, like Clojure's nth."
  (cond ((null coll) nil)
        ((listp coll) (nth i coll))
        ((< i (length coll)) (seq-elt coll i))))

(defun cljbang--drop (coll i)
  "Elements of COLL from index I on, as a list."
  (seq-drop (seq-into coll 'list) i))

(defun cljbang--destructure (pattern val env)
  "Bindings that bind PATTERN to VAL, an elisp form, in `let*' order."
  (cond ((symbolp pattern) (list (list pattern val)))
        ((vectorp pattern) (cljbang--destructure-seq pattern val env))
        ((and (consp pattern) (eq (car pattern) 'cljbang--map-literal))
         (cljbang--destructure-map (cdr pattern) val env))
        (t (error "cljbang: unsupported destructuring pattern %S" pattern))))

(defun cljbang--destructure-seq (vec val env)
  "Bindings for sequential pattern VEC, supporting & and :as."
  (let ((elts (append vec nil)) fixed rest-pat as)
    (while elts
      (let ((p (pop elts)))
        (cond ((eq p '&) (setq rest-pat (pop elts)))
              ((eq p :as) (setq as (pop elts)))
              (t (push p fixed)))))
    (setq fixed (nreverse fixed))
    (let* ((g (gensym "cljbang--seq"))
           (bindings (list (list g val)))
           (i -1))
      (dolist (p fixed)
        (setq i (1+ i))
        (setq bindings
              (nconc bindings (cljbang--destructure p `(cljbang--nth ,g ,i) env))))
      (when rest-pat
        (setq bindings
              (nconc bindings (cljbang--destructure
                               rest-pat `(cljbang--drop ,g ,(length fixed)) env))))
      (when as (setq bindings (nconc bindings (list (list as g)))))
      bindings)))

(defun cljbang--destructure-map (kvs val env)
  "Bindings for associative pattern KVS, supporting :keys, :or and :as.
KVS is the flat key/value list of a map literal; in an explicit pair the
key is the pattern and the value is the map key to look up."
  (let (keys or-kvs as pairs)
    (cl-loop for (k v) on kvs by #'cddr
             do (cond ((eq k :keys) (setq keys (append v nil)))
                      ((eq k :as) (setq as v))
                      ((eq k :or) (setq or-kvs (cdr v)))
                      (t (push (cons k v) pairs))))
    (setq pairs (nreverse pairs))
    (let* ((g (gensym "cljbang--map"))
           (bindings (list (list g val)))
           (lookup (lambda (key pattern)
                     ;; an :or entry keyed by the bound symbol supplies
                     ;; the default third argument to cljbang-get
                     (let ((d (and (symbolp pattern) (plist-member or-kvs pattern))))
                       `(cljbang-get ,g ,key
                                    ,@(when d (list (cljbang-compile (cadr d) env))))))))
      (dolist (s keys)
        (setq bindings
              (nconc bindings
                     (list (list s (funcall lookup
                                            (intern (concat ":" (symbol-name s)))
                                            s))))))
      (dolist (p pairs)
        (setq bindings
              (nconc bindings (cljbang--destructure
                               (car p) (funcall lookup (cdr p) (car p)) env))))
      (when as (setq bindings (nconc bindings (list (list as g)))))
      bindings)))

;;; #(...) anonymous functions
;;
;; The arity comes from the % symbols in the body: % is %1, %2 and up are
;; positional, %& is the rest argument.

(defun cljbang--fn-literal-subst (form)
  "Replace % with %1 in FORM, which Clojure treats as the same argument."
  (cond ((eq form '%) '%1)
        ((vectorp form)
         (apply #'vector (mapcar #'cljbang--fn-literal-subst (append form nil))))
        ((and (consp form) (not (proper-list-p form)))
         (cons (cljbang--fn-literal-subst (car form))
               (cljbang--fn-literal-subst (cdr form))))
        ((consp form) (mapcar #'cljbang--fn-literal-subst form))
        (t form)))

(defun cljbang--fn-literal-scan (form acc)
  "Record % arguments used in FORM into ACC, a cons of (max . rest-p)."
  (cond
   ((and form (symbolp form))
    (let ((name (symbol-name form)))
      (cond ((equal name "%&") (setcdr acc t))
            ((string-match "\\`%\\([0-9]+\\)\\'" name)
             (setcar acc (max (car acc)
                              (string-to-number (match-string 1 name))))))))
   ((vectorp form)
    (mapc (lambda (x) (cljbang--fn-literal-scan x acc)) (append form nil)))
   ((and (consp form) (not (proper-list-p form)))
    (cljbang--fn-literal-scan (car form) acc)
    (cljbang--fn-literal-scan (cdr form) acc))
   ((consp form)
    (mapc (lambda (x) (cljbang--fn-literal-scan x acc)) form)))
  acc)

(defun cljbang--compile-fn-literal (body env)
  "Compile the BODY of a #(...) form to a lambda."
  (let* ((body (cljbang--fn-literal-subst body))
         (acc (cljbang--fn-literal-scan body (cons 0 nil)))
         (params (append (cl-loop for i from 1 to (car acc)
                                  collect (intern (format "%%%d" i)))
                         (when (cdr acc) '(& %&)))))
    (cljbang--compile-fn (vconcat params) (list body) env)))

(defun cljbang--compile-fn (params body env)
  (let ((arglist nil) (patterns nil) (env* env))
    ;; a destructuring param becomes a gensym in the arglist, unpacked by
    ;; a let* wrapped around the body
    (dolist (p (append params nil))
      (cond ((eq p '&) (push '&rest arglist))
            ((symbolp p) (push p arglist) (push p env*))
            (t (let ((g (gensym "cljbang--arg")))
                 (push g arglist)
                 (push (cons p g) patterns)))))
    (setq arglist (nreverse arglist))
    (let (pairs)
      (dolist (pat (nreverse patterns))
        (dolist (b (cljbang--destructure (car pat) (cdr pat) env*))
          (push b pairs)
          (push (car b) env*)))
      (let ((compiled (cljbang--compile-body body env*)))
        `(lambda ,arglist
           ,@(if pairs `((let* ,(nreverse pairs) ,@compiled)) compiled))))))

(defun cljbang--compile-let (bindings body env)
  (let (pairs (env* env))
    (cl-loop for (pattern val) on (append bindings nil) by #'cddr
             do (dolist (b (cljbang--destructure
                            pattern (cljbang-compile val env*) env*))
                  (push b pairs)
                  (push (car b) env*)))
    `(let* ,(nreverse pairs) ,@(cljbang--compile-body body env*))))

(defun cljbang--thread (init forms first?)
  "Expand -> (FIRST? t) or ->> threading."
  (let ((acc init))
    (dolist (f forms acc)
      (setq acc (cond ((not (consp f)) (list f acc))
                      (first? (cons (car f) (cons acc (cdr f))))
                      (t (append f (list acc))))))))

(defun cljbang--resolve (sym)
  "Lisp-1 view over elisp's split namespaces: var first, then function."
  (cond ((boundp sym) (symbol-value sym))
        ((fboundp sym) (symbol-function sym))
        (t (error "Unable to resolve symbol: %s" sym))))

(defun cljbang--assign-target (sym env)
  "Elisp symbol SYM assigns to.  Unlike value position, it stays unevaluated."
  (unless (symbolp sym)
    (error "cljbang: set! needs a symbol, got %S" sym))
  (cond ((memq sym env) sym)
        ((cljbang--el-symbol sym))
        ((cljbang--ns-resolve sym))
        ((cljbang--qualified sym))
        (t sym)))

(defun cljbang--compile-symbol (form env)
  "Compile FORM in value position."
  (cond ((memq form env) form)
        ;; el/ names a var as readily as a function, so resolve it the
        ;; lisp-1 way rather than assuming #'
        ((cljbang--el-symbol form)
         `(cljbang--resolve ',(cljbang--el-symbol form)))
        ((cljbang--qualified form)
         `#',(cljbang--qualified form))
        ((cljbang--ns-resolve form)
         `(cljbang--resolve ',(cljbang--ns-resolve form)))
        ((alist-get form cljbang--core-fns)
         `#',(alist-get form cljbang--core-fns))
        (t `(cljbang--resolve ',form))))

(defun cljbang-compile (form &optional env)
  "Compile Clojure FORM (elisp data) to an elisp form.  ENV = local symbols."
  (cond
   ((null form) nil)
   ((eq form t) t)
   ((eq form 'true) t)
   ((eq form 'false) nil)
   ((keywordp form) form)
   ((symbolp form) (cljbang--compile-symbol form env))
   ((vectorp form)
    `(vector ,@(mapcar (lambda (f) (cljbang-compile f env)) (append form nil))))
   ((not (consp form)) form)
   (t
    (pcase (car form)
      ('cljbang--map-literal
       `(cljbang-hash-map ,@(cljbang--compile-body (cdr form) env)))
      ('cljbang--set-literal
       `(cljbang-hash-set ,@(cljbang--compile-body (cdr form) env)))
      ('cljbang--fn-literal (cljbang--compile-fn-literal (cdr form) env))
      ('quote form)
      ('comment nil)
      ('ns
       (let* ((name (symbol-name (cadr form)))
              (cljbang--load-file-dir (or (cljbang--ns-root name)
                                          cljbang--load-file-dir)))
         (setq cljbang--current-ns name)
         ;; register (:require [lib :as alias]) clauses
         (dolist (clause (cddr form))
           (when (and (consp clause) (eq (car clause) :require))
             (dolist (spec (cdr clause))
               (let* ((spec (if (vectorp spec) (append spec nil) (list spec)))
                      (required (symbol-name (car spec)))
                      (alias-only (cadr (memq :as-alias spec)))
                      (as (or (cadr (memq :as spec)) alias-only)))
                 (when as
                   (setf (alist-get as cljbang--ns-alias-map) required))
                 ;; :as-alias names a namespace without loading it, as in
                 ;; Clojure.  Plain :require loads.
                 (unless alias-only
                   (cljbang--require-ns required))))))
         `(setq cljbang--current-ns ,name)))
      ('def
       (pcase-let* ((`(,name ,val) (cdr form))
                    (name* (cljbang--ns-intern name)))
         `(progn (defvar ,name* nil)
                 (setq ,name* ,(cljbang-compile val env))
                 ',name*)))
      ((or 'defn 'defn-)
       (pcase-let* ((`(,name ,params . ,body) (cdr form))
                    (name* (cljbang--ns-intern name (eq (car form) 'defn-))))
         `(progn (defalias ',name* ,(cljbang--compile-fn params body env))
                 ',name*)))
      ('fn
       (let ((rest (cdr form)))
         (when (symbolp (car rest)) (pop rest)) ; drop optional fn name
         (cljbang--compile-fn (car rest) (cdr rest) env)))
      ('set!
       `(setq ,(cljbang--assign-target (cadr form) env)
              ,(cljbang-compile (caddr form) env)))
      ('let (cljbang--compile-let (cadr form) (cddr form) env))
      ('if `(if ,@(cljbang--compile-body (cdr form) env)))
      ('when `(when ,@(cljbang--compile-body (cdr form) env)))
      ('cond
       ;; :else needs no special case: a keyword is truthy in elisp too
       (let ((clauses (cdr form)))
         (when (cl-oddp (length clauses))
           (error "cljbang: cond needs an even number of forms"))
         `(cond ,@(cl-loop for (test expr) on clauses by #'cddr
                           collect (list (cljbang-compile test env)
                                         (cljbang-compile expr env))))))
      ('do `(progn ,@(cljbang--compile-body (cdr form) env)))
      ('-> (cljbang-compile (cljbang--thread (cadr form) (cddr form) t) env))
      ('->> (cljbang-compile (cljbang--thread (cadr form) (cddr form) nil) env))
      ('with-out-str
       `(with-temp-buffer
          (let ((standard-output (current-buffer)))
            ,@(cljbang--compile-body (cdr form) env))
          (buffer-string)))
      ('time
       (let ((start (gensym "cljbang-time-"))
             (val (gensym "cljbang-val-")))
         `(let* ((,start (current-time))
                 (,val ,(cljbang-compile (cadr form) env)))
            (cljbang-println
             (format "Elapsed time: %.6f msecs"
                     (* 1000 (float-time (time-subtract (current-time) ,start)))))
            ,val)))
      (_ ;; function call
       (let ((head (car form))
             (args (cljbang--compile-body (cdr form) env)))
         (cond
          ;; a keyword looks itself up, and is a symbol, so test it first
          ((keywordp head) `(cljbang-get ,(car args) ,head ,@(cdr args)))
          ((and (symbolp head) (cljbang--qualified head))
           `(,(cljbang--qualified head) ,@args))
          ((and (symbolp head) (cljbang--ns-resolve head))
           `(,(cljbang--ns-resolve head) ,@args))
          ((and (symbolp head) (alist-get head cljbang--core-fns))
           `(,(alist-get head cljbang--core-fns) ,@args))
          ((and (symbolp head) (memq head env))
           `(cljbang--invoke ,head ,@args))
          ((symbolp head) `(,head ,@args))
          (t `(cljbang--invoke ,(cljbang-compile head env) ,@args)))))))))

;;; Entry point

(defun cljbang-eval-string (s)
  "Read Clojure source S, compile each top-level form, eval in-process."
  (let (result)
    (dolist (f (cljbang--splice-braces (cljbang--read-all (cljbang--rewrite-dispatch s)))
               result)
      (setq result (eval (cljbang-compile f) t)))))

;;; Embedded Clojure: elisp's reader already accepts most Clojure
;;; surface syntax (vectors, keywords, quote), so Clojure forms can sit
;;; directly in an elisp buffer and compile at macro-expansion time.
;;; Limitation: #(...) is a read error inside clj!.  Use fn.

;;; {...} needs no reader of its own.  Braces are symbol constituents to
;;; the elisp reader, so {:a 1} comes back as the symbols `{:a' and `1}'
;;; -- the delimiters survive, glued to their neighbours.  Splitting them
;;; back off and reducing the result gives (cljbang--map-literal k v ...),
;;; which the compiler tells apart from a call form.

(defconst cljbang--set-marker 'cljbang--set
  "Symbol #{ is rewritten to, so the elisp reader accepts a set literal.")

(defconst cljbang--dispatch-rewrites
  '(("#{" . "cljbang--set{")
    ;; ( is a real delimiter, so #( becomes a well formed list outright
    ("#(" . "(cljbang--fn-literal "))
  "Reader dispatch forms, and the text the elisp reader accepts instead.")

(defun cljbang--rewrite-dispatch (s)
  "Rewrite #{ and #( in S to forms the elisp reader accepts.
Occurrences inside a string are left alone.  Needs the source text, so
it applies to files and inline evaluation but not to `clj!'."
  (with-temp-buffer
    (insert s)
    (let ((table (make-syntax-table)))
      (modify-syntax-entry ?\" "\"" table)
      (modify-syntax-entry ?\\ "\\" table)
      (set-syntax-table table))
    (let (edits)
      (pcase-dolist (`(,find . ,replace) cljbang--dispatch-rewrites)
        (goto-char (point-min))
        (while (search-forward find nil t)
          ;; syntax-ppss moves point, so keep the search position
          (let ((beg (match-beginning 0)))
            (unless (save-excursion (nth 3 (syntax-ppss beg)))
              (push (list beg (length find) replace) edits))
            (goto-char (+ beg (length find))))))
      ;; latest position first, so the earlier ones stay valid
      (pcase-dolist (`(,pos ,len ,replace)
                     (sort edits (lambda (a b) (> (car a) (car b)))))
        (goto-char pos)
        (delete-char len)
        (insert replace)))
    (buffer-string)))

(defun cljbang--lex-braces (name)
  "Split symbol NAME into tokens, exposing { and } as separate symbols."
  (let (tokens (start 0) (len (length name)))
    (dotimes (i len)
      (when (memq (aref name i) '(?{ ?}))
        (when (> i start)
          (push (car (read-from-string (substring name start i))) tokens))
        (push (if (eq (aref name i) ?{) '\{ '\}) tokens)
        (setq start (1+ i))))
    (when (< start len)
      (push (car (read-from-string (substring name start))) tokens))
    (nreverse tokens)))

(defun cljbang--brace-tokens (form)
  "Expand FORM into the token(s) it contributes to a brace scan."
  (cond
   ;; a comma is whitespace in Clojure, but the elisp reader took it as
   ;; unquote: (\, x) puts x back in the stream
   ((and (consp form) (eq (car form) '\,) (= (length form) 2))
    (cljbang--brace-tokens (cadr form)))
   ((and form (symbolp form) (string-match-p "[{}]" (symbol-name form)))
    (cljbang--lex-braces (symbol-name form)))
   (t (list form))))

(defun cljbang--splice-form (form)
  (cond ((vectorp form) (apply #'vector (cljbang--splice-braces (append form nil))))
        ;; a dotted pair is quoted elisp data, such as an alist.  Braces
        ;; cannot span the dot, so recurse on both sides
        ((and (consp form) (not (proper-list-p form)))
         (cons (cljbang--splice-form (car form)) (cljbang--splice-form (cdr form))))
        ((consp form) (cljbang--splice-braces form))
        (t form)))

(defun cljbang--splice-braces (forms)
  "Reduce { } tokens in FORMS into map and set literal forms."
  (let ((stack (list nil)) kinds)
    (dolist (tok (mapcan #'cljbang--brace-tokens forms))
      (cond
       ((eq tok '\{)
        ;; #{ arrives here as the marker symbol followed by {
        (let ((set? (eq (car (car stack)) cljbang--set-marker)))
          (when set? (setcar stack (cdr (car stack))))
          (push (if set? 'cljbang--set-literal 'cljbang--map-literal) kinds)
          (push nil stack)))
       ((eq tok '\})
        (unless (cdr stack) (error "cljbang: unbalanced } in Clojure form"))
        (let ((m (cons (pop kinds) (nreverse (pop stack)))))
          (push m (car stack))))
       (t (push (cljbang--splice-form tok) (car stack)))))
    (when (cdr stack) (error "cljbang: unbalanced { in Clojure form"))
    (nreverse (car stack))))

(defmacro clj! (&rest forms)
  "Compile Clojure FORMS to elisp at macro-expansion time."
  `(progn ,@(mapcar #'cljbang-compile (cljbang--splice-braces forms))))

;;; Loading whole files: implicit clj! around the file's contents

(defun cljbang--read-all (src)
  "Read all forms from SRC with the elisp reader."
  (let ((pos 0) forms)
    (while (progn (setq pos (or (string-match "[^ \t\n]" src pos) (length src)))
                  (< pos (length src)))
      (condition-case nil
          (pcase-let ((`(,form . ,next) (read-from-string src pos)))
            (push form forms)
            (setq pos next))
        (end-of-file (setq pos (length src))))) ; trailing comment
    (nreverse forms)))

(defun cljbang-load-file (file)
  "Load FILE of Clojure source, as if its contents were wrapped in `clj!'.
Returns the value of the last form."
  (interactive "fLoad Clojure file: ")
  (let ((src (with-temp-buffer
               (insert-file-contents file)
               (buffer-string)))
        ;; an (ns ...) in the file takes effect during the load only,
        ;; like Clojure's load-file preserving the caller's *ns*
        (cljbang--current-ns cljbang--current-ns)
        ;; the root a :require resolves against is derived from the ns
        (cljbang--load-file-name (expand-file-name file))
        (cljbang--load-file-dir (file-name-directory (expand-file-name file))))
    (cljbang-eval-string src)))

;;; Editor integration: eval-last-sexp that respects clj! context

(defvar-local cljbang-whole-buffer nil
  "Non-nil means the whole buffer is Clojure source for evaluation.
Declare it file-locally in a .clj file's first line:
  ;; -*- mode: clojure; cljbang-whole-buffer: t -*-
`cljbang-mode' is then enabled automatically.")
(put 'cljbang-whole-buffer 'safe-local-variable #'booleanp)

(defun cljbang--maybe-enable ()
  (when cljbang-whole-buffer (cljbang-mode 1)))
(add-hook 'hack-local-variables-hook #'cljbang--maybe-enable)

(defun cljbang--clj-context-p ()
  "Non-nil when point is in Clojure context: a whole-buffer cljbang
file, a clojure-mode buffer, or inside a (clj! ...) form."
  (or cljbang-whole-buffer
      (derived-mode-p 'clojure-mode)
      (derived-mode-p 'clojure-ts-mode)
      (cljbang--inside-clj!)))

(defun cljbang--inside-clj! ()
  "Non-nil when point is inside a (clj! ...) form."
  (cl-some (lambda (pos)
             (save-excursion
               (goto-char pos)
               (looking-at-p "(\\s-*clj!\\_>")))
           (nth 9 (syntax-ppss))))

(defface cljbang-result-face
  '((t :inherit shadow :slant italic))
  "Face for inline evaluation result overlays.")

(defvar-local cljbang--result-overlays nil)

(defun cljbang--remove-result-overlays ()
  (mapc #'delete-overlay cljbang--result-overlays)
  (setq cljbang--result-overlays nil)
  (remove-hook 'pre-command-hook #'cljbang--remove-result-overlays 'local))

(defun cljbang--show-result (str pos)
  "Show STR in an overlay after POS until the next command."
  (cljbang--remove-result-overlays)
  (let ((ov (make-overlay pos pos)))
    (overlay-put ov 'after-string
                 (propertize (concat " => " str) 'face 'cljbang-result-face))
    (push ov cljbang--result-overlays)
    (add-hook 'pre-command-hook #'cljbang--remove-result-overlays nil 'local)))

(defun cljbang-eval-last-sexp ()
  "Eval the sexp before point, honoring `clj!' context.
Inside a `clj!' form the sexp text is read and evaluated as Clojure,
including {...} map literals.  The result is shown in an overlay next
to the form and in the echo area.
Elsewhere falls back to `eval-last-sexp'."
  (interactive)
  (if (cljbang--clj-context-p)
      (let* ((beg (save-excursion (backward-sexp) (point)))
             ;; heed the nearest preceding (ns ...) form in the buffer
             (cljbang--current-ns (or (cljbang--buffer-ns) cljbang--current-ns))
             (val (cljbang--pr-str
                   (cljbang-eval-string
                    (buffer-substring-no-properties beg (point))))))
        (cljbang--show-result val (point))
        (message "=> %s" val))
    (call-interactively #'eval-last-sexp)))

(defun cljbang--buffer-ns ()
  "Name of the nearest (ns ...) form before point, or nil."
  (save-excursion
    (when (re-search-backward "(ns[ \t\n]+\\([a-zA-Z0-9._-]+\\)" nil t)
      (match-string-no-properties 1))))

;;; Completion: Clojure names + all of elisp, via completion-at-point

(defconst cljbang--special-forms
  '("def" "defn" "defn-" "fn" "let" "set!" "if" "when" "cond" "do" "ns" "quote"
    "comment" "->" "->>" "time" "with-out-str")
  "Names handled as special forms by `cljbang-compile'.")

(defun cljbang--completion-candidates ()
  "Clojure-side completion candidates: special forms, core fns, ns/aliased vars."
  (let ((cands (copy-sequence cljbang--special-forms)))
    (dolist (c cljbang--core-fns)
      (push (symbol-name (car c)) cands))
    (dolist (a (append cljbang--ns-alias-map cljbang--ns-aliases))
      (let ((prefix (concat (cdr a) "/")))
        (dolist (f cljbang--ns-fns)
          (when (string-prefix-p prefix (car f))
            (push (concat (symbol-name (car a)) "/"
                          (substring (car f) (length prefix)))
                  cands)))))
    (when-let* ((ns (or (cljbang--buffer-ns) cljbang--current-ns))
                (vars (gethash ns cljbang--ns-vars)))
      (maphash (lambda (k _) (push k cands)) vars))
    cands))

(defun cljbang-completion-at-point ()
  "Complete Clojure and elisp symbols in cljbang context."
  (when (cljbang--clj-context-p)
    (let ((beg (save-excursion
                 (skip-chars-backward "^] \t\n(){}\",'`;~@^")
                 (point)))
          (end (point)))
      (when (< beg end)
        (list beg end
              (completion-table-merge
               (cljbang--completion-candidates)
               (apply-partially
                #'completion-table-with-predicate
                obarray
                (lambda (s) (or (fboundp s) (boundp s)))
                t))
              :exclusive 'no)))))

(define-minor-mode cljbang-mode
  "Clojure-aware evaluation inside `clj!' forms.
Remaps \\[eval-last-sexp] so evaluating inside a `clj!' form uses
Clojure semantics, and elisp semantics elsewhere in the buffer.
Adds Clojure- and elisp-symbol completion at point."
  :lighter " clj!"
  :keymap (let ((m (make-sparse-keymap)))
            (define-key m [remap eval-last-sexp] #'cljbang-eval-last-sexp)
            m)
  (if cljbang-mode
      (add-hook 'completion-at-point-functions
                #'cljbang-completion-at-point nil t)
    (remove-hook 'completion-at-point-functions
                 #'cljbang-completion-at-point t)))

(provide 'cljbang)
;;; cljbang.el ends here
