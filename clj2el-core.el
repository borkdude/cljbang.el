;;; clj2el-core.el --- Clojure -> elisp forms, in-memory, no transpiled text -*- lexical-binding: t; -*-

;; POC: read Clojure source with the elisp reader, compile Clojure
;; special forms to elisp forms, and eval them directly in the running
;; Emacs.  No elisp source text is ever printed or re-read.

(require 'cl-lib)
(require 'seq)

;;; Runtime: minimal Clojure core on top of elisp

(defun clj2el-first (coll)
  (if (seq-empty-p coll) nil (seq-elt coll 0)))

(defun clj2el-rest (coll)
  (seq-into (seq-drop coll 1) 'list))

(defun clj2el-second (coll)
  (clj2el-first (clj2el-rest coll)))

(defun clj2el-map (f coll)
  (mapcar (lambda (x) (funcall f x)) (seq-into coll 'list)))

(defun clj2el-filter (pred coll)
  (seq-filter pred (seq-into coll 'list)))

(defun clj2el-reduce (f init coll)
  (seq-reduce f (seq-into coll 'list) init))

(defun clj2el-count (coll)
  (if (hash-table-p coll) (hash-table-count coll) (seq-length coll)))

(defun clj2el-conj (coll x)
  (cond ((vectorp coll) (vconcat coll (vector x)))
        (t (cons x coll))))

(defun clj2el-hash-map (&rest kvs)
  (let ((h (make-hash-table :test #'equal)))
    (while kvs (puthash (pop kvs) (pop kvs) h))
    h))

(defun clj2el-subs (s start &optional end)
  "Substring of S from START to END.
Elisp's substring counts a negative index from the end of the string;
Clojure's subs treats it as out of range, so reject it."
  (when (or (< start 0) (and end (< end 0)))
    (error "String index out of range: %d" (if (< start 0) start end)))
  (substring s start end))

(defun clj2el-nth (coll i &rest not-found)
  "Element I of COLL.  Out of range is an error unless NOT-FOUND is given."
  (cond ((and coll (>= i 0) (< i (clj2el-count coll))) (seq-elt coll i))
        (not-found (car not-found))
        ((null coll) nil)
        (t (error "Index out of bounds: %d" i))))

(defun clj2el-name (x)
  "Name of keyword, symbol or string X, without colon or namespace."
  (cond ((stringp x) x)
        ;; a keyword is a symbol here, so both lose the colon then the ns
        ((symbolp x)
         (let* ((s (symbol-name x))
                (s (if (string-prefix-p ":" s) (substring s 1) s))
                (i (string-search "/" s)))
           (if i (substring s (1+ i)) s)))
        (t (error "clj2el: cannot take name of %S" x))))

(defun clj2el-get (m k &optional default)
  (cond ((hash-table-p m) (gethash k m default))
        ((vectorp m) (if (< k (length m)) (aref m k) default))
        (t default)))

(defun clj2el-assoc (m k v)
  (let ((h (copy-hash-table m)))
    (puthash k v h)
    h))

(defun clj2el--pr-str (x)
  (cond ((null x) "nil")
        ((eq x t) "true")
        ((stringp x) x)
        ((hash-table-p x)
         (let (pairs)
           (maphash (lambda (k v)
                      (push (concat (clj2el--pr-str k) " " (clj2el--pr-str v)) pairs))
                    x)
           (concat "{" (string-join (nreverse pairs) ", ") "}")))
        ((vectorp x)
         (concat "[" (mapconcat #'clj2el--pr-str x " ") "]"))
        ((proper-list-p x)
         (concat "(" (mapconcat #'clj2el--pr-str x " ") ")"))
        (t (format "%s" x))))

(defun clj2el-str (&rest xs)
  (mapconcat (lambda (x) (if (null x) "" (clj2el--pr-str x))) xs ""))

(defun clj2el-println (&rest xs)
  (princ (mapconcat #'clj2el--pr-str xs " "))
  (princ "\n")
  nil)

;;; Clojure name -> elisp function mapping

(defconst clj2el--core-fns
  ;; / is elisp division: integers, no ratios
  '((+ . +) (- . -) (* . *) (/ . /) (mod . mod)
    (= . equal) (not= . clj2el-not=) (< . <) (> . >) (<= . <=) (>= . >=)
    (inc . 1+) (dec . 1-) (not . not)
    (odd? . cl-oddp) (even? . cl-evenp) (zero? . zerop)
    (first . clj2el-first) (second . clj2el-second) (rest . clj2el-rest)
    (map . clj2el-map) (filter . clj2el-filter) (reduce . clj2el-reduce)
    (str . clj2el-str) (println . clj2el-println)
    (get . clj2el-get) (count . clj2el-count)
    (nth . clj2el-nth) (name . clj2el-name)
    (conj . clj2el-conj) (hash-map . clj2el-hash-map)
    (assoc . clj2el-assoc)
    (subs . clj2el-subs)
    (load-file . clj2el-load-file)))

(defun clj2el-not= (a b) (not (equal a b)))

;;; Namespaced symbols: str/join etc.
;;
;; Elisp symbols happily contain `/', so qualified Clojure symbols read
;; as-is.  Aliases map to full namespace names; known vars map to
;; Clojure-semantics wrappers; anything else munges ns/name -> ns--name
;; (dots to dashes), the elisp package convention.  The munge doubles as
;; interop: (mylib/frob x) calls elisp `mylib--frob'.

(defconst clj2el--ns-aliases
  '((str . "clojure.string")))

;; Current namespace: (ns foo) makes subsequent defn/def intern munged
;; names (foobar -> foo--foobar), and unqualified references to names
;; defined in the current ns resolve to those munged symbols.  The
;; registry is consulted at compile time, so within one clj! block a
;; later form can call an earlier defn even though nothing has been
;; evaluated yet.

(defvar clj2el--current-ns nil
  "Name of the current Clojure namespace (a string), or nil.")

(defvar clj2el--ns-alias-map nil
  "Alist of alias symbol -> namespace name, from (ns ... (:require ... :as ...)).")

(defvar clj2el--ns-vars (make-hash-table :test #'equal)
  "Namespace name -> hash table whose keys are var names defined there.")

(defun clj2el--munge-ns (ns)
  (string-replace "." "-" ns))

(defun clj2el--ns-intern (name)
  "Munged elisp symbol for NAME in the current ns; records the var."
  (if clj2el--current-ns
      (let ((vars (or (gethash clj2el--current-ns clj2el--ns-vars)
                      (puthash clj2el--current-ns
                               (make-hash-table :test #'equal)
                               clj2el--ns-vars))))
        (puthash (symbol-name name) t vars)
        (intern (concat (clj2el--munge-ns clj2el--current-ns)
                        "--" (symbol-name name))))
    name))

(defun clj2el--ns-resolve (sym)
  "Munged symbol for SYM when it names a var in the current ns, else nil."
  (when-let* ((ns clj2el--current-ns)
              (vars (gethash ns clj2el--ns-vars)))
    (when (gethash (symbol-name sym) vars)
      (intern (concat (clj2el--munge-ns ns) "--" (symbol-name sym))))))

(defun clj2el-string-join (sep-or-coll &optional coll)
  (let ((sep (if coll sep-or-coll ""))
        (xs (seq-into (or coll sep-or-coll) 'list)))
    (mapconcat #'clj2el-str xs sep)))

(defun clj2el-string-split (s re)
  (apply #'vector (split-string s re)))

(defun clj2el-string-replace (s match rep)
  (replace-regexp-in-string (regexp-quote match) rep s))

(defconst clj2el--ns-fns
  '(("clojure.string/join" . clj2el-string-join)
    ("clojure.string/split" . clj2el-string-split)
    ("clojure.string/replace" . clj2el-string-replace)
    ("clojure.string/upper-case" . upcase)
    ("clojure.string/lower-case" . downcase)
    ("clojure.string/capitalize" . capitalize)
    ("clojure.string/trim" . string-trim)
    ("clojure.string/blank?" . string-blank-p)))

;; el/ is the host environment, the way js/ is in ClojureScript: the name
;; after it is an elisp symbol taken verbatim.  It escapes ns munging
;; (el/my/flymake-inline-ov keeps its slash) and the clj2el--core-fns
;; overrides, so elisp's own get, assoc, + ... stay reachable.

(defun clj2el--el-symbol (sym)
  "Elisp symbol named by an el/ qualified SYM, or nil."
  (let ((name (symbol-name sym)))
    (when (and (string-prefix-p "el/" name) (> (length name) 3))
      (intern (substring name 3)))))

(defun clj2el--qualified (sym)
  "Resolve ns-qualified SYM to an elisp function symbol, or nil."
  (let ((name (symbol-name sym)))
    (or (clj2el--el-symbol sym)
        (when (and (> (length name) 1)
                   (string-search "/" name)
                   (not (string-prefix-p "/" name))
                   (not (string-suffix-p "/" name)))
          (let ((parts (split-string name "/")))
            (unless (= (length parts) 2)
              (error "clj2el: %s has more than one /; use el/%s for an elisp name"
                     name name))
            (pcase-let* ((`(,ns ,n) parts)
                         (full (or (cdr (assq (intern ns) clj2el--ns-alias-map))
                                   (cdr (assq (intern ns) clj2el--ns-aliases))
                                   ns)))
              (or (cdr (assoc (concat full "/" n) clj2el--ns-fns))
                  (intern (concat (string-replace "." "-" full) "--" n)))))))))

;;; Compiler: Clojure form -> elisp form

(defun clj2el--compile-body (forms env)
  (mapcar (lambda (f) (clj2el-compile f env)) forms))

;;; Destructuring
;;
;; let bindings and fn params take the same patterns, so both funnel
;; through clj2el--destructure, which flattens one pattern into plain
;; let* pairs.  A pattern binds its value to a gensym and then indexes
;; into it (sequential) or looks keys up in it (associative).  Patterns
;; nest, so the expansion recurses.

(defun clj2el--nth (coll i)
  "Element I of COLL, or nil when out of range, like Clojure's nth."
  (cond ((null coll) nil)
        ((listp coll) (nth i coll))
        ((< i (length coll)) (seq-elt coll i))))

(defun clj2el--drop (coll i)
  "Elements of COLL from index I on, as a list."
  (seq-drop (seq-into coll 'list) i))

(defun clj2el--destructure (pattern val env)
  "Bindings that bind PATTERN to VAL, an elisp form, in `let*' order."
  (cond ((symbolp pattern) (list (list pattern val)))
        ((vectorp pattern) (clj2el--destructure-seq pattern val env))
        ((and (consp pattern) (eq (car pattern) 'clj2el--map-literal))
         (clj2el--destructure-map (cdr pattern) val env))
        (t (error "clj2el: unsupported destructuring pattern %S" pattern))))

(defun clj2el--destructure-seq (vec val env)
  "Bindings for sequential pattern VEC, supporting & and :as."
  (let ((elts (append vec nil)) fixed rest-pat as)
    (while elts
      (let ((p (pop elts)))
        (cond ((eq p '&) (setq rest-pat (pop elts)))
              ((eq p :as) (setq as (pop elts)))
              (t (push p fixed)))))
    (setq fixed (nreverse fixed))
    (let* ((g (gensym "clj2el--seq"))
           (bindings (list (list g val)))
           (i -1))
      (dolist (p fixed)
        (setq i (1+ i))
        (setq bindings
              (nconc bindings (clj2el--destructure p `(clj2el--nth ,g ,i) env))))
      (when rest-pat
        (setq bindings
              (nconc bindings (clj2el--destructure
                               rest-pat `(clj2el--drop ,g ,(length fixed)) env))))
      (when as (setq bindings (nconc bindings (list (list as g)))))
      bindings)))

(defun clj2el--destructure-map (kvs val env)
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
    (let* ((g (gensym "clj2el--map"))
           (bindings (list (list g val)))
           (lookup (lambda (key pattern)
                     ;; an :or entry keyed by the bound symbol supplies
                     ;; the default third argument to clj2el-get
                     (let ((d (and (symbolp pattern) (plist-member or-kvs pattern))))
                       `(clj2el-get ,g ,key
                                    ,@(when d (list (clj2el-compile (cadr d) env))))))))
      (dolist (s keys)
        (setq bindings
              (nconc bindings
                     (list (list s (funcall lookup
                                            (intern (concat ":" (symbol-name s)))
                                            s))))))
      (dolist (p pairs)
        (setq bindings
              (nconc bindings (clj2el--destructure
                               (car p) (funcall lookup (cdr p) (car p)) env))))
      (when as (setq bindings (nconc bindings (list (list as g)))))
      bindings)))

(defun clj2el--compile-fn (params body env)
  (let ((arglist nil) (patterns nil) (env* env))
    ;; a destructuring param becomes a gensym in the arglist, unpacked by
    ;; a let* wrapped around the body
    (dolist (p (append params nil))
      (cond ((eq p '&) (push '&rest arglist))
            ((symbolp p) (push p arglist) (push p env*))
            (t (let ((g (gensym "clj2el--arg")))
                 (push g arglist)
                 (push (cons p g) patterns)))))
    (setq arglist (nreverse arglist))
    (let (pairs)
      (dolist (pat (nreverse patterns))
        (dolist (b (clj2el--destructure (car pat) (cdr pat) env*))
          (push b pairs)
          (push (car b) env*)))
      (let ((compiled (clj2el--compile-body body env*)))
        `(lambda ,arglist
           ,@(if pairs `((let* ,(nreverse pairs) ,@compiled)) compiled))))))

(defun clj2el--compile-let (bindings body env)
  (let (pairs (env* env))
    (cl-loop for (pattern val) on (append bindings nil) by #'cddr
             do (dolist (b (clj2el--destructure
                            pattern (clj2el-compile val env*) env*))
                  (push b pairs)
                  (push (car b) env*)))
    `(let* ,(nreverse pairs) ,@(clj2el--compile-body body env*))))

(defun clj2el--thread (init forms first?)
  "Expand -> (FIRST? t) or ->> threading."
  (let ((acc init))
    (dolist (f forms acc)
      (setq acc (cond ((not (consp f)) (list f acc))
                      (first? (cons (car f) (cons acc (cdr f))))
                      (t (append f (list acc))))))))

(defun clj2el--resolve (sym)
  "Lisp-1 view over elisp's split namespaces: var first, then function."
  (cond ((boundp sym) (symbol-value sym))
        ((fboundp sym) (symbol-function sym))
        (t (error "Unable to resolve symbol: %s" sym))))

(defun clj2el--assign-target (sym env)
  "Elisp symbol SYM assigns to.  Unlike value position, it stays unevaluated."
  (unless (symbolp sym)
    (error "clj2el: set! needs a symbol, got %S" sym))
  (cond ((memq sym env) sym)
        ((clj2el--el-symbol sym))
        ((clj2el--ns-resolve sym))
        ((clj2el--qualified sym))
        (t sym)))

(defun clj2el--compile-symbol (form env)
  "Compile FORM in value position."
  (cond ((memq form env) form)
        ;; el/ names a var as readily as a function, so resolve it the
        ;; lisp-1 way rather than assuming #'
        ((clj2el--el-symbol form)
         `(clj2el--resolve ',(clj2el--el-symbol form)))
        ((clj2el--qualified form)
         `#',(clj2el--qualified form))
        ((clj2el--ns-resolve form)
         `(clj2el--resolve ',(clj2el--ns-resolve form)))
        ((alist-get form clj2el--core-fns)
         `#',(alist-get form clj2el--core-fns))
        (t `(clj2el--resolve ',form))))

(defun clj2el-compile (form &optional env)
  "Compile Clojure FORM (elisp data) to an elisp form.  ENV = local symbols."
  (cond
   ((null form) nil)
   ((eq form t) t)
   ((eq form 'true) t)
   ((eq form 'false) nil)
   ((keywordp form) form)
   ((symbolp form) (clj2el--compile-symbol form env))
   ((vectorp form)
    `(vector ,@(mapcar (lambda (f) (clj2el-compile f env)) (append form nil))))
   ((not (consp form)) form)
   (t
    (pcase (car form)
      ('clj2el--map-literal
       `(clj2el-hash-map ,@(clj2el--compile-body (cdr form) env)))
      ('quote form)
      ('comment nil)
      ('ns
       (let ((name (symbol-name (cadr form))))
         (setq clj2el--current-ns name)
         ;; register (:require [lib :as alias]) clauses
         (dolist (clause (cddr form))
           (when (and (consp clause) (eq (car clause) :require))
             (dolist (spec (cdr clause))
               ;; :as-alias behaves like :as here, there being nothing to
               ;; load.  el/ resolves to the host environment either way.
               (let* ((spec (if (vectorp spec) (append spec nil) (list spec)))
                      (as (or (cadr (memq :as spec))
                              (cadr (memq :as-alias spec)))))
                 (when as
                   (setf (alist-get as clj2el--ns-alias-map)
                         (symbol-name (car spec))))))))
         `(setq clj2el--current-ns ,name)))
      ('def
       (pcase-let* ((`(,name ,val) (cdr form))
                    (name* (clj2el--ns-intern name)))
         `(progn (defvar ,name* nil)
                 (setq ,name* ,(clj2el-compile val env))
                 ',name*)))
      ('defn
       (pcase-let* ((`(,name ,params . ,body) (cdr form))
                    (name* (clj2el--ns-intern name)))
         `(progn (defalias ',name* ,(clj2el--compile-fn params body env))
                 ',name*)))
      ('fn
       (let ((rest (cdr form)))
         (when (symbolp (car rest)) (pop rest)) ; drop optional fn name
         (clj2el--compile-fn (car rest) (cdr rest) env)))
      ('set!
       `(setq ,(clj2el--assign-target (cadr form) env)
              ,(clj2el-compile (caddr form) env)))
      ('let (clj2el--compile-let (cadr form) (cddr form) env))
      ('if `(if ,@(clj2el--compile-body (cdr form) env)))
      ('when `(when ,@(clj2el--compile-body (cdr form) env)))
      ('cond
       ;; :else needs no special case: a keyword is truthy in elisp too
       (let ((clauses (cdr form)))
         (when (cl-oddp (length clauses))
           (error "clj2el: cond needs an even number of forms"))
         `(cond ,@(cl-loop for (test expr) on clauses by #'cddr
                           collect (list (clj2el-compile test env)
                                         (clj2el-compile expr env))))))
      ('do `(progn ,@(clj2el--compile-body (cdr form) env)))
      ('-> (clj2el-compile (clj2el--thread (cadr form) (cddr form) t) env))
      ('->> (clj2el-compile (clj2el--thread (cadr form) (cddr form) nil) env))
      ('with-out-str
       `(with-temp-buffer
          (let ((standard-output (current-buffer)))
            ,@(clj2el--compile-body (cdr form) env))
          (buffer-string)))
      ('time
       (let ((start (gensym "clj2el-time-"))
             (val (gensym "clj2el-val-")))
         `(let* ((,start (current-time))
                 (,val ,(clj2el-compile (cadr form) env)))
            (clj2el-println
             (format "Elapsed time: %.6f msecs"
                     (* 1000 (float-time (time-subtract (current-time) ,start)))))
            ,val)))
      (_ ;; function call
       (let ((head (car form))
             (args (clj2el--compile-body (cdr form) env)))
         (cond
          ((and (symbolp head) (clj2el--qualified head))
           `(,(clj2el--qualified head) ,@args))
          ((and (symbolp head) (clj2el--ns-resolve head))
           `(,(clj2el--ns-resolve head) ,@args))
          ((and (symbolp head) (alist-get head clj2el--core-fns))
           `(,(alist-get head clj2el--core-fns) ,@args))
          ((and (symbolp head) (memq head env))
           `(funcall ,head ,@args))
          ((symbolp head) `(,head ,@args))
          (t `(funcall ,(clj2el-compile head env) ,@args)))))))))

;;; Entry point

(defun clj2el-eval-string (s)
  "Read Clojure source S, compile each top-level form, eval in-process."
  (let (result)
    (dolist (f (clj2el--splice-braces (clj2el--read-all s)) result)
      (setq result (eval (clj2el-compile f) t)))))

;;; Embedded Clojure: elisp's reader already accepts most Clojure
;;; surface syntax (vectors, keywords, quote), so Clojure forms can sit
;;; directly in an elisp buffer and compile at macro-expansion time.
;;; Limitation: #(...) is a read error inside clj!.  Use fn.

;;; {...} needs no reader of its own.  Braces are symbol constituents to
;;; the elisp reader, so {:a 1} comes back as the symbols `{:a' and `1}'
;;; -- the delimiters survive, glued to their neighbours.  Splitting them
;;; back off and reducing the result gives (clj2el--map-literal k v ...),
;;; which the compiler tells apart from a call form.

(defun clj2el--lex-braces (name)
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

(defun clj2el--brace-tokens (form)
  "Expand FORM into the token(s) it contributes to a brace scan."
  (cond
   ;; a comma is whitespace in Clojure, but the elisp reader took it as
   ;; unquote: (\, x) puts x back in the stream
   ((and (consp form) (eq (car form) '\,) (= (length form) 2))
    (clj2el--brace-tokens (cadr form)))
   ((and form (symbolp form) (string-match-p "[{}]" (symbol-name form)))
    (clj2el--lex-braces (symbol-name form)))
   (t (list form))))

(defun clj2el--splice-form (form)
  (cond ((vectorp form) (apply #'vector (clj2el--splice-braces (append form nil))))
        ;; a dotted pair is quoted elisp data, such as an alist.  Braces
        ;; cannot span the dot, so recurse on both sides
        ((and (consp form) (not (proper-list-p form)))
         (cons (clj2el--splice-form (car form)) (clj2el--splice-form (cdr form))))
        ((consp form) (clj2el--splice-braces form))
        (t form)))

(defun clj2el--splice-braces (forms)
  "Reduce { } tokens in FORMS into (clj2el--map-literal ...) forms."
  (let ((stack (list nil)))
    (dolist (tok (mapcan #'clj2el--brace-tokens forms))
      (cond
       ((eq tok '\{) (push nil stack))
       ((eq tok '\})
        (unless (cdr stack) (error "clj2el: unbalanced } in Clojure form"))
        (let ((m (cons 'clj2el--map-literal (nreverse (pop stack)))))
          (push m (car stack))))
       (t (push (clj2el--splice-form tok) (car stack)))))
    (when (cdr stack) (error "clj2el: unbalanced { in Clojure form"))
    (nreverse (car stack))))

(defmacro clj! (&rest forms)
  "Compile Clojure FORMS to elisp at macro-expansion time."
  `(progn ,@(mapcar #'clj2el-compile (clj2el--splice-braces forms))))

;;; Loading whole files: implicit clj! around the file's contents

(defun clj2el--read-all (src)
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

(defun clj2el-load-file (file)
  "Load FILE of Clojure source, as if its contents were wrapped in `clj!'.
Returns the value of the last form."
  (interactive "fLoad Clojure file: ")
  (let ((src (with-temp-buffer
               (insert-file-contents file)
               (buffer-string)))
        ;; an (ns ...) in the file takes effect during the load only,
        ;; like Clojure's load-file preserving the caller's *ns*
        (clj2el--current-ns clj2el--current-ns))
    (clj2el-eval-string src)))

;;; Editor integration: eval-last-sexp that respects clj! context

(defvar-local clj2el-whole-buffer nil
  "Non-nil means the whole buffer is Clojure source for evaluation.
Declare it file-locally in a .clj file's first line:
  ;; -*- mode: clojure; clj2el-whole-buffer: t -*-
`clj2el-mode' is then enabled automatically.")
(put 'clj2el-whole-buffer 'safe-local-variable #'booleanp)

(defun clj2el--maybe-enable ()
  (when clj2el-whole-buffer (clj2el-mode 1)))
(add-hook 'hack-local-variables-hook #'clj2el--maybe-enable)

(defun clj2el--clj-context-p ()
  "Non-nil when point is in Clojure context: a whole-buffer clj2el
file, a clojure-mode buffer, or inside a (clj! ...) form."
  (or clj2el-whole-buffer
      (derived-mode-p 'clojure-mode)
      (derived-mode-p 'clojure-ts-mode)
      (clj2el--inside-clj!)))

(defun clj2el--inside-clj! ()
  "Non-nil when point is inside a (clj! ...) form."
  (cl-some (lambda (pos)
             (save-excursion
               (goto-char pos)
               (looking-at-p "(\\s-*clj!\\_>")))
           (nth 9 (syntax-ppss))))

(defface clj2el-result-face
  '((t :inherit shadow :slant italic))
  "Face for inline evaluation result overlays.")

(defvar-local clj2el--result-overlays nil)

(defun clj2el--remove-result-overlays ()
  (mapc #'delete-overlay clj2el--result-overlays)
  (setq clj2el--result-overlays nil)
  (remove-hook 'pre-command-hook #'clj2el--remove-result-overlays 'local))

(defun clj2el--show-result (str pos)
  "Show STR in an overlay after POS until the next command."
  (clj2el--remove-result-overlays)
  (let ((ov (make-overlay pos pos)))
    (overlay-put ov 'after-string
                 (propertize (concat " => " str) 'face 'clj2el-result-face))
    (push ov clj2el--result-overlays)
    (add-hook 'pre-command-hook #'clj2el--remove-result-overlays nil 'local)))

(defun clj2el-eval-last-sexp ()
  "Eval the sexp before point, honoring `clj!' context.
Inside a `clj!' form the sexp text is read and evaluated as Clojure,
including {...} map literals.  The result is shown in an overlay next
to the form and in the echo area.
Elsewhere falls back to `eval-last-sexp'."
  (interactive)
  (if (clj2el--clj-context-p)
      (let* ((beg (save-excursion (backward-sexp) (point)))
             ;; heed the nearest preceding (ns ...) form in the buffer
             (clj2el--current-ns (or (clj2el--buffer-ns) clj2el--current-ns))
             (val (clj2el--pr-str
                   (clj2el-eval-string
                    (buffer-substring-no-properties beg (point))))))
        (clj2el--show-result val (point))
        (message "=> %s" val))
    (call-interactively #'eval-last-sexp)))

(defun clj2el--buffer-ns ()
  "Name of the nearest (ns ...) form before point, or nil."
  (save-excursion
    (when (re-search-backward "(ns[ \t\n]+\\([a-zA-Z0-9._-]+\\)" nil t)
      (match-string-no-properties 1))))

;;; Completion: Clojure names + all of elisp, via completion-at-point

(defconst clj2el--special-forms
  '("def" "defn" "fn" "let" "set!" "if" "when" "cond" "do" "ns" "quote"
    "comment" "->" "->>" "time" "with-out-str")
  "Names handled as special forms by `clj2el-compile'.")

(defun clj2el--completion-candidates ()
  "Clojure-side completion candidates: special forms, core fns, ns/aliased vars."
  (let ((cands (copy-sequence clj2el--special-forms)))
    (dolist (c clj2el--core-fns)
      (push (symbol-name (car c)) cands))
    (dolist (a (append clj2el--ns-alias-map clj2el--ns-aliases))
      (let ((prefix (concat (cdr a) "/")))
        (dolist (f clj2el--ns-fns)
          (when (string-prefix-p prefix (car f))
            (push (concat (symbol-name (car a)) "/"
                          (substring (car f) (length prefix)))
                  cands)))))
    (when-let* ((ns (or (clj2el--buffer-ns) clj2el--current-ns))
                (vars (gethash ns clj2el--ns-vars)))
      (maphash (lambda (k _) (push k cands)) vars))
    cands))

(defun clj2el-completion-at-point ()
  "Complete Clojure and elisp symbols in clj2el context."
  (when (clj2el--clj-context-p)
    (let ((beg (save-excursion
                 (skip-chars-backward "^] \t\n(){}\",'`;~@^")
                 (point)))
          (end (point)))
      (when (< beg end)
        (list beg end
              (completion-table-merge
               (clj2el--completion-candidates)
               (apply-partially
                #'completion-table-with-predicate
                obarray
                (lambda (s) (or (fboundp s) (boundp s)))
                t))
              :exclusive 'no)))))

(define-minor-mode clj2el-mode
  "Clojure-aware evaluation inside `clj!' forms.
Remaps \\[eval-last-sexp] so evaluating inside a `clj!' form uses
Clojure semantics, and elisp semantics elsewhere in the buffer.
Adds Clojure- and elisp-symbol completion at point."
  :lighter " clj!"
  :keymap (let ((m (make-sparse-keymap)))
            (define-key m [remap eval-last-sexp] #'clj2el-eval-last-sexp)
            m)
  (if clj2el-mode
      (add-hook 'completion-at-point-functions
                #'clj2el-completion-at-point nil t)
    (remove-hook 'completion-at-point-functions
                 #'clj2el-completion-at-point t)))

(provide 'clj2el-core)
;;; clj2el-core.el ends here
