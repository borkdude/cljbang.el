;;; cljbang.el --- Clojure that runs as Emacs Lisp -*- lexical-binding: t; -*-

;; Version: 0.0.3
;; Package-Requires: ((emacs "28.1"))
;; Homepage: https://github.com/borkdude/cljbang.el
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
;; string-join, if-let* and when-let* live here before Emacs 29
(require 'subr-x)
(require 'cljbang-core)
(require 'cljbang-string)

;;; Clojure name -> elisp function mapping

(defconst cljbang--core-fns
  ;; / is elisp division: integers, no ratios
  '((+ . +) (- . -) (* . *) (/ . /) (mod . mod)
    (= . cljbang-=) (not= . cljbang-not=) (< . <) (> . >) (<= . <=) (>= . >=)
    (inc . 1+) (dec . 1-) (not . not)
    (odd? . cl-oddp) (even? . cl-evenp) (zero? . zerop)
    (first . cljbang-first) (second . cljbang-second) (rest . cljbang-rest)
    (last . cljbang-last)
    (map . cljbang-map) (filter . cljbang-filter) (remove . cljbang-remove)
    (reduce . cljbang-reduce) (concat . cljbang-concat) (sort . cljbang-sort)
    (str . cljbang-str) (println . cljbang-println)
    (pr-str . cljbang-pr-str) (prn . cljbang-prn)
    (get . cljbang-get) (count . cljbang-count)
    (nth . cljbang-nth) (name . cljbang-name)
    (conj . cljbang-conj) (hash-map . cljbang-hash-map)
    (hash-set . cljbang-hash-set) (contains? . cljbang-contains?)
    (assoc . cljbang-assoc)
    (subs . cljbang-subs) (throw . cljbang-throw)
    (ex-info . cljbang-ex-info) (ex-message . cljbang-ex-message)
    (ex-data . cljbang-ex-data) (ex-cause . cljbang-ex-cause)
    (re-pattern . cljbang-re-pattern) (re-find . cljbang-re-find)
    (re-matches . cljbang-re-matches) (re-seq . cljbang-re-seq)
    (load-file . cljbang-load-file)))


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

(defvar cljbang--macros (make-hash-table :test #'equal)
  "Macro name -> expander function.
Registered while compiling, so a later form in the same file can use a
macro defined above it, as `cljbang--ns-vars' does for defn.")

(defvar cljbang--expanding 0
  "Depth of macro expansion, to catch a macro that expands to itself.")

(defvar cljbang--ns-vars (make-hash-table :test #'equal)
  "Namespace name -> hash table whose keys are var names defined there.")

(defun cljbang--munge-ns (ns)
  (string-replace "." "-" ns))

;;; Loading what :require names

(defgroup cljbang nil
  "Clojure that runs as Emacs Lisp."
  :group 'languages
  :prefix "cljbang-")

(defcustom cljbang-load-path nil
  "Directories searched for the .clj files a require names.
The source root of the file being loaded is searched first, so this is
what `cljbang-require' has to go on when called from elisp."
  :type '(repeat directory)
  :group 'cljbang)

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

(defun cljbang--prefix-in-use-p (ns)
  "Whether any bound symbol is named with NS as an elisp prefix.
Emacs has whole families of built-ins whose prefix names no feature, so
string- and buffer- are legitimate aliases with nothing to load."
  (let ((prefix (concat (cljbang--munge-ns ns) "-")))
    (catch 'cljbang--found
      (mapatoms (lambda (sym)
                  (when (and (string-prefix-p prefix (symbol-name sym))
                             (or (fboundp sym) (boundp sym)))
                    (throw 'cljbang--found t))))
      nil)))

(defun cljbang--require-ns (ns)
  "Load NS: a .clj file when one is on the load path, else an elisp feature.
An alias for a prefix that names no feature is allowed when something is
actually defined under it, so a typo is still an error."
  (unless (or (gethash ns cljbang--loaded-ns)
              ;; namespaces cljbang implements itself
              (rassoc ns cljbang--ns-aliases))
    ;; marked before loading, so a cycle terminates
    (puthash ns t cljbang--loaded-ns)
    (let ((file (cljbang--find-ns-file ns)))
      (cond (file (cljbang-load-file file))
            ((require (intern ns) nil 'noerror))
            ((cljbang--prefix-in-use-p ns))
            (t (error "cljbang: cannot require %s, no such file, feature or %s- name"
                      ns (cljbang--munge-ns ns)))))))

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

;; el/ is the host environment, the way js/ is in ClojureScript: the name
;; after it is an elisp symbol taken verbatim.  It escapes ns munging
;; (el/my/flymake-inline-ov keeps its slash) and the cljbang--core-fns
;; overrides, so elisp's own get, assoc, + ... stay reachable.

(defun cljbang--register-macro (name ns expander)
  "Register EXPANDER as the macro NAME, in NS when there is one."
  (puthash name expander cljbang--macros)
  (when ns (puthash (concat ns "/" name) expander cljbang--macros))
  nil)

(defun cljbang--require-spec (spec)
  "Register the alias in SPEC and load what it names.
Returns the namespace to load at run time, or nil for :as-alias, which
names a namespace without loading it as in Clojure."
  (let* ((spec (if (vectorp spec) (append spec nil) (list spec)))
         (required (symbol-name (car spec)))
         (alias-only (cadr (memq :as-alias spec)))
         (as (or (cadr (memq :as spec)) alias-only)))
    (when as
      (setf (alist-get as cljbang--ns-alias-map) required))
    (unless alias-only
      (cljbang--require-ns required)
      required)))

(defun cljbang--macro-function (sym)
  "Expander registered for SYM, plain or namespace qualified, or nil."
  (let ((name (symbol-name sym)))
    (or (and cljbang--current-ns
             (gethash (concat cljbang--current-ns "/" name) cljbang--macros))
        (gethash name cljbang--macros)
        (when (string-search "/" name)
          (pcase-let ((`(,ns ,n) (split-string name "/")))
            (gethash (concat (or (cdr (assq (intern ns) cljbang--ns-alias-map)) ns)
                             "/" n)
                     cljbang--macros))))))

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

;; Clojure calls only a few of these special forms; the rest are macros
;; there.  cljbang knows them all, until enough of it is written in
;; cljbang itself.
(defconst cljbang--special-forms
  '("def" "defn" "defn-" "defmacro" "fn" "let" "set!" "if" "do"
    "try" "ns" "require" "quote" "comment")
  "Names `cljbang-compile' handles itself.")

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

(defun cljbang--split-docstring (rest)
  "Split REST of a defn into (DOC PARAMS BODY), doc being optional."
  (if (stringp (car rest))
      (list (car rest) (cadr rest) (cddr rest))
    (list nil (car rest) (cdr rest))))

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

;; condition-case takes its handlers as clauses rather than expressions, so
;; try is compiled rather than expanded.  Clojure has it as a special form
;; too.  One gensym holds the error for every handler, since condition-case
;; binds a single variable.
(defun cljbang--catch-symbol (sym)
  "Elisp error symbol for the SYM a catch clause names."
  (cond ((eq sym :default) t)
        ((memq sym '(Exception Throwable Error))
         (error "cljbang: catch takes an elisp error symbol, not %s" sym))
        ((symbolp sym) sym)
        (t (error "cljbang: catch needs an error symbol, got %S" sym))))

(defun cljbang--compile-try (forms env)
  "Compile the FORMS of a try: a body, then catch and finally clauses."
  (let (body handlers finally)
    (dolist (form forms)
      (pcase form
        (`(catch ,sym ,var . ,handler)
         (push (list (cljbang--catch-symbol sym) var handler) handlers))
        (`(finally . ,cleanup)
         (setq finally cleanup))
        ((or `(catch . ,_) `(finally . ,_))
         (error "cljbang: malformed clause %S" form))
        (_ (when (or handlers finally)
             (error "cljbang: try body must come before catch and finally"))
           (push form body))))
    (let* ((err (gensym "cljbang-err-"))
           (compiled `(progn ,@(cljbang--compile-body (nreverse body) env)))
           (caught
            (if (null handlers)
                compiled
              `(condition-case ,err
                   ,compiled
                 ,@(mapcar
                    (lambda (h)
                      (pcase-let ((`(,sym ,var ,handler) h))
                        `(,sym (let ((,var (cljbang--caught ,err)))
                                 ,@(cljbang--compile-body handler (cons var env))))))
                    (nreverse handlers))))))
      (if finally
          `(unwind-protect ,caught ,@(cljbang--compile-body finally env))
        caught))))

(defun cljbang--thread (init forms first?)
  "Expand -> (FIRST? t) or ->> threading."
  (let ((acc init))
    (dolist (f forms acc)
      (setq acc (cond ((not (consp f)) (list f acc))
                      (first? (cons (car f) (cons acc (cdr f))))
                      (t (append f (list acc))))))))


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
        ;; a qualified name may be a def as readily as a defn, so resolve
        ;; it the lisp-1 way rather than assuming #'
        ((cljbang--qualified form)
         `(cljbang--resolve ',(cljbang--qualified form)))
        ((cljbang--ns-resolve form)
         `(cljbang--resolve ',(cljbang--ns-resolve form)))
        ((alist-get form cljbang--core-fns)
         `#',(alist-get form cljbang--core-fns))
        (t `(cljbang--resolve ',form))))

(defcustom cljbang-warn-unresolved t
  "Whether to warn when a qualified name resolves to nothing defined.
An autoloaded function counts as defined, so this catches a typo like
magti/status without complaining about magit/status."
  :type 'boolean
  :group 'cljbang)

(defun cljbang--interned-here-p (sym)
  "Whether SYM is a var cljbang interned, which may not be evaluated yet."
  (catch 'cljbang--found
    (maphash (lambda (_ns vars)
               (maphash (lambda (_name s)
                          (when (eq s sym) (throw 'cljbang--found t)))
                        vars))
             cljbang--ns-vars)
    nil))

(defun cljbang--warn-unresolved (sym original)
  "Warn that ORIGINAL resolved to SYM, which nothing defines."
  (when (and cljbang-warn-unresolved
             (not (fboundp sym))
             (not (boundp sym))
             (not (cljbang--interned-here-p sym)))
    (display-warning 'cljbang
                     (format "%s resolves to %s, which is not defined"
                             original sym)
                     :warning))
  sym)

(defun cljbang--compile-call (form env)
  "Compile FORM, a macro call or a function call, in ENV."
  (let ((head (car form)))
    (if-let* ((expander (and (symbolp head)
                             (not (memq head env))
                             (cljbang--macro-function head))))
        ;; a macro sees its arguments unevaluated, so expand before compiling
        (progn
          (when (> cljbang--expanding 100)
            (error "cljbang: %s expands without end" head))
          (let ((cljbang--expanding (1+ cljbang--expanding)))
            (cljbang-compile (apply expander (cdr form)) env)))
      (let ((args (cljbang--compile-body (cdr form) env)))
        (cond
         ;; a keyword looks itself up, and is a symbol, so test it first
         ((keywordp head) `(cljbang-get ,(car args) ,head ,@(cdr args)))
         ((and (symbolp head) (cljbang--qualified head))
          `(,(cljbang--warn-unresolved (cljbang--qualified head) head) ,@args))
         ((and (symbolp head) (cljbang--ns-resolve head))
          `(,(cljbang--ns-resolve head) ,@args))
         ((and (symbolp head) (alist-get head cljbang--core-fns))
          `(,(alist-get head cljbang--core-fns) ,@args))
         ((and (symbolp head) (memq head env))
          `(cljbang--invoke ,head ,@args))
         ((symbolp head) `(,head ,@args))
         (t `(cljbang--invoke ,(cljbang-compile head env) ,@args)))))))

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
      ('require
       ;; specs are quoted, as in Clojure
       (let ((loaded (mapcar (lambda (arg)
                               (cljbang--require-spec
                                (if (and (consp arg) (eq (car arg) 'quote))
                                    (cadr arg)
                                  arg)))
                             (cdr form))))
         `(progn ,@(mapcar (lambda (ns) `(cljbang-require ,ns))
                           (delq nil loaded))
                 nil)))
      ('ns
       (let* ((name (symbol-name (cadr form)))
              (cljbang--load-file-dir (or (cljbang--ns-root name)
                                          cljbang--load-file-dir)))
         (setq cljbang--current-ns name)
         ;; register (:require [lib :as alias]) clauses
         (let (loaded)
           (dolist (clause (cddr form))
             (when (and (consp clause) (eq (car clause) :require))
               (dolist (spec (cdr clause))
                 (push (cljbang--require-spec spec) loaded))))
           ;; the loads are emitted as well as run, so a file restored
           ;; from its cache still pulls in what it requires
           `(progn (setq cljbang--current-ns ,name)
                   ,@(mapcar (lambda (ns) `(cljbang-require ,ns))
                             (delq nil (nreverse loaded)))))))
      ('def
       (pcase-let* ((`(,name . ,rest) (cdr form))
                    (doc (and (cdr rest) (stringp (car rest)) (pop rest)))
                    (name* (cljbang--ns-intern name)))
         `(progn (defvar ,name* nil ,@(when doc (list doc)))
                 (setq ,name* ,(cljbang-compile (car rest) env))
                 ',name*)))
      ('defmacro
       (pcase-let* ((`(,name . ,rest) (cdr form))
                    (`(,_doc ,params ,body) (cljbang--split-docstring rest))
                    (name* (cljbang--ns-intern name))
                    (fn (cljbang--compile-fn params body env)))
         ;; registered now, so the rest of this file can use it, and
         ;; emitted too, so a compiled file registers it again on load
         (cljbang--register-macro (symbol-name name) cljbang--current-ns (eval fn t))
         `(progn (cljbang--register-macro ,(symbol-name name)
                                          ,cljbang--current-ns ,fn)
                 ',name*)))
      ((or 'defn 'defn-)
       (pcase-let* ((`(,name . ,rest) (cdr form))
                    (`(,doc ,params ,body) (cljbang--split-docstring rest))
                    (name* (cljbang--ns-intern name (eq (car form) 'defn-)))
                    (fn (cljbang--compile-fn params body env)))
         ;; a docstring goes where elisp keeps one, so C-h f finds it
         (when doc (setq fn `(lambda ,(cadr fn) ,doc ,@(cddr fn))))
         `(progn (defalias ',name* ,fn) ',name*)))
      ('fn
       (let ((rest (cdr form)))
         (when (symbolp (car rest)) (pop rest)) ; drop optional fn name
         (cljbang--compile-fn (car rest) (cdr rest) env)))
      ('set!
       `(setq ,(cljbang--assign-target (cadr form) env)
              ,(cljbang-compile (caddr form) env)))
      ('let (cljbang--compile-let (cadr form) (cddr form) env))
      ('try (cljbang--compile-try (cdr form) env))
      ('if `(if ,@(cljbang--compile-body (cdr form) env)))
      ('do `(progn ,@(cljbang--compile-body (cdr form) env)))
      (_ (cljbang--compile-call form env))))))

;;; Entry point

(defun cljbang--read-forms (s)
  "Clojure source S as forms, ready for `cljbang-compile'."
  (cljbang--splice-braces (cljbang--read-all (cljbang--rewrite-dispatch s))))

(defun cljbang-eval-string (s)
  "Read Clojure source S, compile each top-level form, eval in-process."
  (let (result)
    ;; compiled and evaluated one at a time, so a form can rely on what
    ;; the forms above it did
    (dolist (f (cljbang--read-forms s) result)
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
      ;; #"..." needs a closing paren after the string, so it takes two
      ;; edits and has to find where the string ends
      (goto-char (point-min))
      (while (search-forward "#\"" nil t)
        (let ((beg (match-beginning 0)))
          (unless (save-excursion (nth 3 (syntax-ppss beg)))
            (goto-char (1+ beg))              ; on the opening quote
            (let ((end (save-excursion (forward-sexp) (point))))
              (push (list end 0 ")") edits)
              (push (list beg 2 "(cljbang-re-pattern \"") edits)
              (goto-char end)))))
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

(defconst cljbang--quote-marker 'cljbang--quote
  "Stands in for a quote whose form the reader broke across brace tokens.")

(defun cljbang--brace-tokens (form)
  "Expand FORM into the token(s) it contributes to a brace scan."
  (cond
   ;; a comma is whitespace in Clojure, but the elisp reader took it as
   ;; unquote: (\, x) puts x back in the stream
   ((and (consp form) (eq (car form) '\,) (= (length form) 2))
    (cljbang--brace-tokens (cadr form)))
   ;; '{:a 1} reads as the quoted symbol `{:a' followed by `1}', so the
   ;; quote has swallowed the opening brace.  Put it back as a marker and
   ;; let the scan below decide what it applies to.
   ((and (consp form) (eq (car form) 'quote) (= (length form) 2)
         (cljbang--needs-splice-p (cadr form)))
    (cons cljbang--quote-marker (cljbang--brace-tokens (cadr form))))
   ((and form (symbolp form) (string-match-p "[{}]" (symbol-name form)))
    (cljbang--lex-braces (symbol-name form)))
   (t (list form))))

(defun cljbang--quote-literal (form)
  "Quote FORM as Clojure quotes a literal collection, element by element."
  (cond ((and (consp form)
              (memq (car form) '(cljbang--map-literal cljbang--set-literal)))
         (cons (car form) (mapcar #'cljbang--quote-literal (cdr form))))
        ((vectorp form)
         (apply #'vector (mapcar #'cljbang--quote-literal (append form nil))))
        (t (list 'quote form))))

(defun cljbang--needs-splice-p (form)
  "Whether FORM holds a brace or a comma, so the splicing pass has work.
Most forms hold neither, and this walk allocates nothing, so checking
first is cheaper than building a token list for every one."
  (cond ((and form (symbolp form))
         (let ((name (symbol-name form)))
           (or (string-search "{" name) (string-search "}" name))))
        ((vectorp form) (seq-some #'cljbang--needs-splice-p form))
        ((consp form) (or (eq (car form) '\,)
                          (cljbang--needs-splice-p (car form))
                          (cljbang--needs-splice-p (cdr form))))
        (t nil)))

(defun cljbang--splice-form (form)
  (cond ((not (cljbang--needs-splice-p form)) form)
        ((vectorp form) (apply #'vector (cljbang--splice-braces (append form nil))))
        ;; a dotted pair is quoted elisp data, such as an alist.  Braces
        ;; cannot span the dot, so recurse on both sides
        ((and (consp form) (not (proper-list-p form)))
         (cons (cljbang--splice-form (car form)) (cljbang--splice-form (cdr form))))
        ((consp form) (cljbang--splice-braces form))
        (t form)))

(defun cljbang--splice-braces (forms)
  "Reduce { } tokens in FORMS into map and set literal forms."
  (if (not (seq-some #'cljbang--needs-splice-p forms))
      forms
    (cljbang--splice-braces-1 forms)))

(defun cljbang--splice-braces-1 (forms)
  "Do the splicing that `cljbang--splice-braces' decided is needed."
  (let ((stack (list nil)) kinds quoted pending)
    (dolist (tok (mapcan #'cljbang--brace-tokens forms))
      (cond
       ((eq tok cljbang--quote-marker) (setq pending t))
       ((eq tok '\{)
        ;; #{ arrives here as the marker symbol followed by {
        (let ((set? (eq (car (car stack)) cljbang--set-marker)))
          (when set? (setcar stack (cdr (car stack))))
          (push (if set? 'cljbang--set-literal 'cljbang--map-literal) kinds)
          (push pending quoted)
          (setq pending nil)
          (push nil stack)))
       ((eq tok '\})
        (unless (cdr stack) (error "cljbang: unbalanced } in Clojure form"))
        (let* ((was-quoted (pop quoted))
               (m (cons (pop kinds) (nreverse (pop stack)))))
          (push (if was-quoted (cljbang--quote-literal m) m) (car stack))))
       ;; the set marker is not a value, so a pending quote passes over it
       ;; to the brace that follows
       ((eq tok cljbang--set-marker) (push tok (car stack)))
       (t (let ((v (cljbang--splice-form tok)))
            (push (if pending (progn (setq pending nil) (list 'quote v)) v)
                  (car stack))))))
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

(defconst cljbang-version "0.0.3"
  "Version of cljbang, which a compiled cache is keyed on.")

(defun cljbang--cache-file (file)
  "Name of the byte-compiled cache for FILE.
The Emacs version and the cljbang version are part of the name, so
upgrading either one misses the old cache rather than loading output
that no longer matches the compiler that made it."
  (format "%s.%d-%s.elc" file emacs-major-version cljbang-version))

(defun cljbang-compile-file (file)
  "Byte-compile FILE, a .clj, to a .elc beside it.
`cljbang-load-file' then loads that instead of running the compiler
again, which is what makes a .clj file as cheap to load as elisp."
  (interactive "fCompile Clojure file: ")
  (let* ((file (expand-file-name file))
         (src (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (cljbang--current-ns cljbang--current-ns)
         (cljbang--load-file-name file)
         (cljbang--load-file-dir (file-name-directory file))
         ;; named so byte-compile-file lands on the cache name
         (scratch (substring (cljbang--cache-file file) 0 -1))
         (compiled (mapcar #'cljbang-compile (cljbang--read-forms src))))
    (unwind-protect
        (progn
          (with-temp-file scratch
            (insert ";;; generated by cljbang-compile-file -*- lexical-binding: t -*-\n")
            (insert "(require 'cljbang-core)\n")
            (dolist (f (butlast compiled))
              (prin1 f (current-buffer))
              (insert "\n"))
            ;; so a cached load can still return the last form's value
            (when compiled
              (prin1 `(setq cljbang--file-value ,(car (last compiled)))
                     (current-buffer))
              (insert "\n")))
          (byte-compile-file scratch))
      (when (file-exists-p scratch) (delete-file scratch)))
    (cljbang--cache-file file)))

(defvar cljbang--file-value nil
  "Value of the last form of the file just loaded from a cache.")

(defun cljbang--load-file-uncached (file)
  "Compile and evaluate FILE without touching a cache."
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

(defun cljbang-require (ns &optional reload)
  "Load namespace NS, the way a :require inside an ns form does.
NS is a symbol or a string.  It resolves to a .clj file along
`cljbang-load-path', or to an elisp feature of that name.  Loading
happens once unless RELOAD is non-nil."
  (interactive "SNamespace: ")
  (let ((ns (if (stringp ns) ns (symbol-name ns))))
    (when reload (remhash ns cljbang--loaded-ns))
    (cljbang--require-ns ns)
    ns))

;; neither of these needs compiler support, they are just macros.  The
;; expansion is cljbang code, so it goes through the compiler in turn.
(cljbang--register-macro
 "->" nil
 (lambda (init &rest forms) (cljbang--thread init forms t)))

(cljbang--register-macro
 "->>" nil
 (lambda (init &rest forms) (cljbang--thread init forms nil)))

(cljbang--register-macro
 "when" nil
 (lambda (test &rest body) (list 'if test (cons 'do body))))

(cljbang--register-macro
 "cond" nil
 (lambda (&rest clauses)
   (when (cl-oddp (length clauses))
     (error "cljbang: cond needs an even number of forms"))
   (let (pairs)
     (while clauses
       (push (list (car clauses) (cadr clauses)) pairs)
       (setq clauses (cddr clauses)))
     ;; pairs runs backwards, so folding builds the ifs inside out
     (let (expansion)
       (dolist (pair pairs expansion)
         (setq expansion (list 'if (car pair) (cadr pair) expansion)))))))

;; The test is bound to a gensym and destructured inside the branch, so it
;; runs once and a pattern that binds nothing still decides the branch.
(defun cljbang--if-let (binding then else)
  "Expansion of if-let over BINDING, one pattern and one test, THEN and ELSE."
  (unless (and (vectorp binding) (= 2 (length binding)))
    (error "cljbang: if-let needs exactly one binding pair"))
  (let ((test (gensym "cljbang-if-let-")))
    (list 'let (vector test (aref binding 1))
          (list 'if test
                (list 'let (vector (aref binding 0) test) then)
                else))))

(cljbang--register-macro
 "if-let" nil
 (lambda (binding then &optional else) (cljbang--if-let binding then else)))

(cljbang--register-macro
 "when-let" nil
 (lambda (binding &rest body) (cljbang--if-let binding (cons 'do body) nil)))

;; seq-do rather than dolist, since the binding is a cljbang pattern and
;; fn already destructures it.  Each clause wraps the ones after it, so
;; later pairs nest and a :let or :when scopes over the rest, as in Clojure.
(defun cljbang--doseq-clauses (clauses body)
  "Body forms for the doseq CLAUSES that remain, wrapping BODY."
  (if (zerop (length clauses))
      body
    (let ((head (aref clauses 0))
          (form (aref clauses 1))
          (more (substring clauses 2)))
      (cond
       ((eq head :let)
        (list (cons 'let (cons form (cljbang--doseq-clauses more body)))))
       ((eq head :when)
        (list (cons 'when (cons form (cljbang--doseq-clauses more body)))))
       ((keywordp head)
        (error "cljbang: doseq does not support %s" head))
       (t
        (list (list 'do
                    (list 'el/seq-do
                          (cons 'fn (cons (vector head)
                                          (cljbang--doseq-clauses more body)))
                          form)
                    nil)))))))

(defun cljbang--doseq (bindings body)
  "Expansion of doseq over BINDINGS, pairs and modifiers, and BODY."
  (unless (and (vectorp bindings) (> (length bindings) 0)
               (cl-evenp (length bindings))
               (not (keywordp (aref bindings 0))))
    (error "cljbang: doseq needs a binding pair first"))
  (car (cljbang--doseq-clauses bindings body)))

(defun cljbang--dotimes (binding body)
  "Expansion of dotimes over BINDING, a name and a count, and BODY."
  (unless (and (vectorp binding) (= 2 (length binding)))
    (error "cljbang: dotimes needs exactly one binding pair"))
  (let ((n (gensym "cljbang-n-"))
        (i (gensym "cljbang-i-")))
    (list 'let (vector n (aref binding 1) i 0)
          (list 'el/while (list '< i n)
                (cons 'let (cons (vector (aref binding 0) i) body))
                (list 'set! i (list 'inc i)))
          nil)))

(cljbang--register-macro
 "doseq" nil
 (lambda (bindings &rest body) (cljbang--doseq bindings body)))

(cljbang--register-macro
 "dotimes" nil
 (lambda (binding &rest body) (cljbang--dotimes binding body)))

(cljbang--register-macro
 "with-out-str" nil
 (lambda (&rest body) (cons 'el/with-output-to-string body)))

(cljbang--register-macro
 "time" nil
 (lambda (expr)
   (let ((start (gensym "cljbang-start-"))
         (val (gensym "cljbang-val-")))
     (list 'let (vector start '(el/current-time)
                        val expr)
           (list 'println
                 (list 'el/format "Elapsed time: %.6f msecs"
                       (list '* 1000
                             (list 'el/float-time
                                   (list 'el/time-subtract
                                         '(el/current-time) start)))))
           val))))

(defun cljbang-load-file (file)
  "Load FILE of Clojure source, as if its contents were wrapped in `clj!'.
The compiled result is cached beside FILE and reused until FILE changes,
so loading costs about what the equivalent elisp would.  A directory
that cannot be written simply gets no cache.  Returns the value of the
last form."
  (interactive "fLoad Clojure file: ")
  (let* ((file (expand-file-name file))
         (cache (cljbang--cache-file file))
         ;; an (ns ...) in the file takes effect during the load only,
         ;; whether it ran now or was baked into the cache
         (cljbang--current-ns cljbang--current-ns)
         ;; a require emitted into the cache resolves against the same
         ;; place it did when the file was compiled
         (cljbang--load-file-name file)
         (cljbang--load-file-dir (file-name-directory file)))
    (cond
     ((file-newer-than-file-p cache file)
      (load cache nil t)
      cljbang--file-value)
     ;; no cache to be had, so just run it
     ((not (file-writable-p (file-name-directory file)))
      (cljbang--load-file-uncached file))
     (t
      (cljbang-compile-file file)
      (load cache nil t)
      cljbang--file-value))))



(provide 'cljbang)
;;; cljbang.el ends here