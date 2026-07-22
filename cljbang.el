;;; cljbang.el --- Clojure that runs as Emacs Lisp -*- lexical-binding: t; -*-

;; Version: 0.0.7
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
    (list . list)
    (seq . cljbang-seq) (vec . cljbang-vec) (set . cljbang-set)
    (mapv . cljbang-mapv)
    (mapcat . cljbang-mapcat) (into . cljbang-into) (range . cljbang-range)
    (take . cljbang-take) (drop . cljbang-drop)
    (take-while . cljbang-take-while) (drop-while . cljbang-drop-while)
    (distinct . cljbang-distinct) (some . cljbang-some)
    (every? . cljbang-every?) (sort-by . cljbang-sort-by)
    (empty? . cljbang-empty?) (apply . cljbang-apply)
    (keys . cljbang-keys) (vals . cljbang-vals) (merge . cljbang-merge)
    (dissoc . cljbang-dissoc) (select-keys . cljbang-select-keys)
    (update . cljbang-update) (get-in . cljbang-get-in)
    (assoc-in . cljbang-assoc-in) (update-in . cljbang-update-in)
    (partial . cljbang-partial) (comp . cljbang-comp)
    (complement . cljbang-complement) (constantly . cljbang-constantly)
    (atom . cljbang-atom) (deref . cljbang-deref)
    (reset! . cljbang-reset!) (swap! . cljbang-swap!)
    (keyword . cljbang-keyword) (symbol . cljbang-symbol)
    (nil? . cljbang-nil?) (some? . cljbang-some?) (map? . cljbang-map?)
    (set? . cljbang-set?)
    (fn? . cljbang-fn?) (symbol? . cljbang-symbol?)
    (string? . stringp) (number? . numberp) (integer? . integerp)
    (int? . integerp) (keyword? . keywordp) (vector? . vectorp)
    (pos? . cl-plusp) (neg? . cl-minusp)
    (re-pattern . cljbang-re-pattern) (re-find . cljbang-re-find)
    (re-matches . cljbang-re-matches) (re-seq . cljbang-re-seq)
    (slurp . cljbang-slurp) (spit . cljbang-spit)
    (load-file . cljbang-load-file)))


;;; Namespaced symbols: str/join etc.
;;
;; Elisp symbols happily contain `/', so qualified Clojure symbols read
;; as-is.  Aliases map to full namespace names, known vars map to
;; Clojure-semantics wrappers, and anything else munges ns/name to
;; ns-name with dots as dashes.  The munge doubles as interop:
;; (magit/status) calls elisp `magit-status'.

(defconst cljbang--core-macros
  '((when . cljbang-core-when) (cond . cljbang-core-cond)
    (case . cljbang-core-case) (if-let . cljbang-core-if-let)
    (when-let . cljbang-core-when-let) (doseq . cljbang-core-doseq)
    (dotimes . cljbang-core-dotimes) (-> . cljbang-core->)
    (->> . cljbang-core->>) (some-> . cljbang-core-some->)
    (some->> . cljbang-core-some->>) (with-out-str . cljbang-core-with-out-str)
    (time . cljbang-core-time))
  "Clojure name -> the elisp symbol a macro cljbang ships is interned as.")

(defconst cljbang--ns-default-aliases
  '((str . "clojure.string") (edn . "clojure.edn")))

;; Current namespace: (ns foo) makes subsequent defn/def intern munged
;; names (bar -> foo-bar, or foo--bar for defn-), and references to names
;; defined in the current ns resolve to those munged symbols.  The
;; registry is consulted at compile time, so within one clj! block a
;; later form can call an earlier defn even though nothing has been
;; evaluated yet.

;; The namespace in effect, the aliases it declared and the vars it
;; defined all live in `cljbang--ns-state', which cljbang-core.el owns
;; because a compiled file sets the namespace when it loads.

(defvar cljbang--expanding 0
  "Depth of macro expansion, to catch a macro that expands to itself.")

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

(defcustom cljbang-warn-unresolved t
  "Whether to warn when a qualified name resolves to nothing defined.
An autoloaded function counts as defined, so this catches a typo like
magti/status without complaining about magit/status."
  :type 'boolean
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
              (rassoc ns cljbang--ns-default-aliases))
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
  (if-let* ((ns (cljbang--current-ns)))
      (let* ((sym (intern (concat (cljbang--munge-ns ns)
                                  (if private "--" "-")
                                  (symbol-name name))))
             (prev (cljbang--interned-as sym))
             (here (cons ns (symbol-name name))))
        (when (and prev (not (equal prev here)))
          (display-warning 'cljbang
                           (format "%s/%s interns %s, already %s/%s"
                                   ns name sym (car prev) (cdr prev))
                           :warning))
        (puthash sym here (cljbang--interned-table))
        ;; store the symbol, so resolving does not have to guess which
        ;; spelling this var was defined with
        (puthash (symbol-name name) sym (cljbang--ns-var-table))
        sym)
    name))

(defun cljbang--ns-resolve (sym)
  "Munged symbol for SYM when it names a var in the current ns, else nil."
  (when (cljbang--current-ns)
    (gethash (symbol-name sym) (cljbang--ns-var-table))))

;; el/ is the host environment, the way js/ is in ClojureScript: the name
;; after it is an elisp symbol taken verbatim.  It escapes ns munging
;; (el/my/flymake-inline-ov keeps its slash) and the cljbang--core-fns
;; overrides, so elisp's own get, assoc, + ... stay reachable.

(defun cljbang--spec-parts (spec)
  "SPEC as a list, whatever shape a require wrote it in."
  (if (vectorp spec) (append spec nil) (list spec)))

(defun cljbang--spec-alias (spec)
  "The (ALIAS . NAMESPACE) that a require SPEC declares, or nil."
  (let* ((parts (cljbang--spec-parts spec))
         (as (or (cadr (memq :as parts)) (cadr (memq :as-alias parts)))))
    (when as (cons as (symbol-name (car parts))))))

(defun cljbang--require-spec (spec)
  "Register the alias in SPEC and load what it names.
Returns the namespace to load at run time, or nil for :as-alias, which
names a namespace without loading it as in Clojure."
  (let* ((parts (cljbang--spec-parts spec))
         (required (symbol-name (car parts)))
         (alias-only (cadr (memq :as-alias parts))))
    (when-let* ((alias (cljbang--spec-alias spec)))
      (cljbang--ns-add-alias (car alias) (cdr alias)))
    (unless alias-only
      (cljbang--require-ns required)
      required)))

(defun cljbang--emit-aliases (specs)
  "Forms that register the aliases SPECS declare, for a cached load."
  (delq nil (mapcar (lambda (spec)
                      (when-let* ((alias (cljbang--spec-alias spec)))
                        `(cljbang--ns-add-alias ',(car alias) ,(cdr alias))))
                    specs)))

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
                         (full (or (cdr (assq (intern ns) (cljbang--ns-aliases)))
                                   (cdr (assq (intern ns) cljbang--ns-default-aliases))
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
  '("def" "defn" "defn-" "defmacro" "fn" "let" "loop" "recur" "set!" "if" "do"
    "try" "ns" "require" "quote" "comment")
  "Names `cljbang-compile' handles itself.")

(defvar cljbang--recur-target nil
  "Slots, temporaries and flag a recur rebinds, or nil outside a loop.")

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
    (cljbang--compile-arity (vconcat params) (list body) env)))

(defun cljbang--split-docstring (rest)
  "Split REST of a defn into (DOC TAIL), doc being optional."
  (if (stringp (car rest))
      (list (car rest) (cdr rest))
    (list nil rest)))

(defun cljbang--fn-arities (tail)
  "TAIL of a fn or defn as a list of (PARAMS BODY), one for each arity."
  (cond ((vectorp (car tail)) (list (list (car tail) (cdr tail))))
        ((null tail) (error "cljbang: a fn needs a parameter vector"))
        (t (mapcar (lambda (arity)
                     (unless (and (consp arity) (vectorp (car arity)))
                       (error "cljbang: a fn arity is a vector and a body, got %S"
                              arity))
                     (list (car arity) (cdr arity)))
                   tail))))

(defun cljbang--compile-fn (tail env)
  "Compile the TAIL of a fn: one parameter vector and body, or several."
  (let ((arities (cljbang--fn-arities tail)))
    (if (cdr arities)
        (cljbang--compile-arities arities env)
      (cljbang--compile-arity (caar arities) (cadar arities) env))))

;; Elisp dispatches on nothing, so the arities share one &rest lambda that
;; picks by argument count.  Each arity binds its own parameters and is its
;; own recur target, the way each is a separate body in Clojure.
(defun cljbang--compile-arities (arities env)
  (let ((args (gensym "cljbang-args-"))
        (n (gensym "cljbang-n-"))
        clauses)
    (dolist (arity arities)
      (pcase-let* ((`(,params ,body) arity)
                   (`(,test ,form) (cljbang--compile-arity-clause
                                    params body args n env)))
        (push (list test form) clauses)))
    `(lambda (&rest ,args)
       (let ((,n (length ,args)))
         (cond ,@(nreverse clauses)
               (t (error "cljbang: no arity takes %d argument(s)" ,n)))))))

(defun cljbang--compile-arity-clause (params body args n env)
  "A (TEST FORM) clause binding PARAMS from ARGS, whose length is N."
  (let* ((names (append params nil))
         (rest-at (cl-position '& names))
         (fixed (if rest-at (cl-subseq names 0 rest-at) names))
         (rest-param (when rest-at (nth (1+ rest-at) names)))
         (env* env)
         inits slots bound)
    (cl-loop for param in fixed
             for i from 0
             do (let ((slot (if (symbolp param) param (gensym "cljbang--arg"))))
                  (push (list slot `(nth ,i ,args)) inits)
                  (push slot slots)
                  (if (symbolp param)
                      (push param env*)
                    (dolist (b (cljbang--destructure param slot env*))
                      (push b bound)
                      (push (car b) env*)))))
    (when rest-param
      (let ((slot (if (symbolp rest-param) rest-param (gensym "cljbang--arg"))))
        (push (list slot `(nthcdr ,(length fixed) ,args)) inits)
        (push slot slots)
        (if (symbolp rest-param)
            (push rest-param env*)
          (dolist (b (cljbang--destructure rest-param slot env*))
            (push b bound)
            (push (car b) env*)))))
    (list (if rest-at `(>= ,n ,(length fixed)) `(= ,n ,(length fixed)))
          `(let* ,(nreverse inits)
             ,@(cljbang--compile-recur-body
                (nreverse slots) (nreverse bound) body env*)))))

(defun cljbang--compile-arity (params body env)
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
      ;; the parameters are the recur target, so a tail recur re-enters the
      ;; function without a call, as it does in Clojure
      `(lambda ,arglist
         ,@(cljbang--compile-recur-body (remq '&rest arglist)
                                        (nreverse pairs) body env*)))))

;; A syntax quote builds the form rather than quoting it: every part is
;; quoted except what an unquote marks.  A trailing # gives one gensym per
;; name per template, which is what keeps a macro from capturing a binding.

(defun cljbang--auto-gensym (sym gensyms)
  "Gensym for SYM, a name ending in #, the same one throughout GENSYMS."
  (let ((name (symbol-name sym)))
    (or (gethash name gensyms)
        (puthash name
                 (gensym (concat (substring name 0 -1) "-"))
                 gensyms))))

(defconst cljbang--template-bare
  '(& catch finally cljbang--map-literal cljbang--set-literal)
  "Names a template leaves alone: & as Clojure leaves it, and the clause
heads of try, which are syntax rather than names of their own.")

(defun cljbang--template-qualified (sym)
  "SYM with its alias expanded, still qualified.
el/ and a name already spelled in full are left alone."
  (let ((parts (split-string (symbol-name sym) "/")))
    (if (or (cljbang--el-symbol sym) (not (= (length parts) 2)))
        sym
      (pcase-let ((`(,ns ,n) parts))
        (if-let* ((full (or (cdr (assq (intern ns) (cljbang--ns-aliases)))
                            (cdr (assq (intern ns) cljbang--ns-default-aliases)))))
            (intern (concat full "/" n))
          sym)))))

(defun cljbang--template-symbol (sym)
  "SYM as a template should carry it.
A macro expands wherever it is called, so an unqualified name is
qualified to the namespace it was written in, whether or not the var
exists yet.  A qualified name keeps its shape, and what cljbang defines
resolves to what it names, so nothing at the call site can take its
place.  Special forms are matched before anything is resolved, so they
stay as they are."
  (let ((name (symbol-name sym)))
    (cond
     ((memq sym cljbang--template-bare) sym)
     ((member name cljbang--special-forms) sym)
     ((string-search "/" name) (cljbang--template-qualified sym))
     ;; the defined var knows whether defn- spelled it private
     ((cljbang--ns-resolve sym))
     ;; resolved, or a name of its own at the call site would take it
     ((alist-get sym cljbang--core-fns))
     ((alist-get sym cljbang--core-macros))
     ;; a macro defined outside any namespace is already its own name
     ((cljbang--macro-function sym) sym)
     ;; a name the compiler made, met again when a nested syntax quote
     ;; walks build code, is already what it should be
     ((or (rassq sym cljbang--core-fns)
          (rassq sym cljbang--core-macros)
          (cljbang--interned-as sym)
          (not (intern-soft name)))
      sym)
     ((cljbang--current-ns)
      (let ((prefix (concat (cljbang--munge-ns (cljbang--current-ns)) "-")))
        (if (string-prefix-p prefix name)
            sym
          (intern (concat prefix name)))))
     (t sym))))

(defun cljbang--template (form gensyms)
  "Cljbang form that builds FORM, honouring unquote.  GENSYMS holds x# names."
  (when (and (consp form) (memq (car form) '(\` \, \,@)))
    (error "cljbang: ` and ~ need source text, so they do not work inside clj!"))
  (pcase form
    ;; innermost first, as Clojure reads it: the inner template expands,
    ;; and the outer one builds that expansion as data
    (`(cljbang--syntax-quote ,inner)
     (cljbang--template
      (cljbang--template inner (make-hash-table :test #'equal))
      gensyms))
    (`(cljbang--unquote ,x) x)
    (`(cljbang--unquote-splicing ,_)
     (error "cljbang: ~@ only makes sense inside a collection"))
    ((pred keywordp) form)
    ((pred symbolp)
     (cond ((null form) nil)
           ((memq form '(t true false)) form)
           ((string-suffix-p "#" (symbol-name form))
            (list 'quote (cljbang--auto-gensym form gensyms)))
           (t (list 'quote (cljbang--template-symbol form)))))
    ((pred vectorp)
     (list 'vec (cljbang--template-seq (append form nil) gensyms)))
    (`(cljbang--fn-literal . ,_)
     (error "cljbang: #() inside a syntax quote does not work, use (fn [x#] ...)"))
    (`(cljbang--map-literal . ,kvs)
     (list 'apply 'hash-map (cljbang--template-seq kvs gensyms)))
    (`(cljbang--set-literal . ,xs)
     (list 'apply 'hash-set (cljbang--template-seq xs gensyms)))
    ((pred consp) (cljbang--template-seq form gensyms))
    (_ form)))

(defun cljbang--template-seq (forms gensyms)
  "Cljbang form building the list FORMS, splicing where ~@ says to."
  (let (parts run spliced)
    (dolist (f forms)
      (pcase f
        (`(cljbang--unquote-splicing ,x)
         (when run (push (cons 'list (nreverse run)) parts) (setq run nil))
         (setq spliced t)
         (push x parts))
        (_ (push (cljbang--template f gensyms) run))))
    (when run (push (cons 'list (nreverse run)) parts))
    (setq parts (nreverse parts))
    (cond ((null parts) nil)
          ;; concat even for one part when it was spliced in, since what
          ;; was spliced may be a vector and the result is a list
          ((and (null (cdr parts)) (not spliced)) (car parts))
          (t (cons 'concat parts)))))

(defun cljbang--compile-syntax-quote (form env)
  (cljbang-compile (cljbang--template form (make-hash-table :test #'equal)) env))

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
  "Elisp error symbol for the SYM a catch clause names.
:default catches everything, as it does in ClojureScript, and el/ names a
host error the way js/Error does there."
  (let ((err (cond ((eq sym :default) t)
                   ((cljbang--el-symbol sym))
                   ((memq sym '(Exception Throwable Error))
                    (error "cljbang: catch takes an elisp error symbol or :default, not %s"
                           sym))
                   ((symbolp sym) sym)
                   (t (error "cljbang: catch needs an error symbol, got %S" sym)))))
    ;; a symbol naming no condition matches nothing, so the error would
    ;; sail past a clause that looks right
    (when (and cljbang-warn-unresolved
               (not (eq err t))
               (not (get err 'error-conditions)))
      (display-warning 'cljbang
                       (format "catch %s names no error condition, so it never matches"
                               sym)
                       :warning))
    err))

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

;; Each binding gets a slot holding its raw value, destructured afresh at
;; the top of every pass, so a loop pattern works the way a let one does.
;; recur fills the temporaries first and copies them over after the body,
;; which is what makes the rebinding simultaneous.
(defun cljbang--compile-loop (bindings body env)
  "Compile a loop over BINDINGS with BODY, looping on recur."
  (let* ((pairs (cl-loop for (pattern val) on (append bindings nil) by #'cddr
                         collect (list pattern val)))
         (slots (mapcar (lambda (_) (gensym "cljbang-loop-")) pairs))
         (env* env)
         inits bound)
    (cl-loop for (_ val) in pairs
             for slot in slots
             do (push (list slot (cljbang-compile val env)) inits))
    (cl-loop for (pattern _) in pairs
             for slot in slots
             do (dolist (b (cljbang--destructure pattern slot env*))
                  (push b bound)
                  (push (car b) env*)))
    `(let* ,(nreverse inits)
       ,@(cljbang--compile-recur-body slots (nreverse bound) body env*))))

;; Shared by loop and fn, which differ only in where the slots come from:
;; a loop initialises them itself, a fn takes them as arguments.  The while
;; is emitted only when the body holds a recur, so an ordinary function
;; compiles to the lambda it would have before.
(defun cljbang--compile-recur-body (slots bound body env)
  "Compile BODY, with SLOTS as the recur target and BOUND unpacking them.
Returns a list of forms, looping when a recur asks for it."
  (let* ((temps (mapcar (lambda (_) (gensym "cljbang-recur-")) slots))
         (again (gensym "cljbang-again-"))
         (result (gensym "cljbang-result-"))
         (compiled (let ((cljbang--recur-target (list slots temps again)))
                     (cljbang--compile-body body env))))
    (cljbang--check-recur-body compiled t)
    (if (not (cl-some #'cljbang--has-recur compiled))
        (if bound `((let* ,bound ,@compiled)) compiled)
      (setq compiled (mapcar #'cljbang--strip-recur-marks compiled))
      `((let* (,@temps (,again t) (,result nil))
          (while ,again
            (setq ,again nil)
            (let* ,bound (setq ,result (progn ,@compiled)))
            (when ,again
              (setq ,@(cl-loop for slot in slots for temp in temps
                               append (list slot temp)))))
          ,result)))))

(defun cljbang--has-recur (form)
  "Whether FORM holds a recur mark."
  (cond ((not (consp form)) nil)
        ((not (proper-list-p form)) nil)
        ((eq (car form) 'quote) nil)
        ((eq (car form) 'cljbang--recur) t)
        (t (cl-some #'cljbang--has-recur form))))

(defun cljbang--compile-recur (args env)
  (unless cljbang--recur-target
    (error "cljbang: recur outside of a loop"))
  (pcase-let ((`(,slots ,temps ,again) cljbang--recur-target))
    (unless (= (length args) (length slots))
      (error "cljbang: recur wants %d argument(s), got %d"
             (length slots) (length args)))
    ;; cljbang--recur is a mark the loop checks the position of and then
    ;; rewrites to progn, since tail position is only known once the whole
    ;; body is compiled and the macros in it are gone
    `(cljbang--recur
      (setq ,@(cl-loop for temp in temps for arg in args
                       append (list temp (cljbang-compile arg env))))
      (setq ,again t)
      nil)))

;; Clojure rejects a recur that is not in tail position, and cljbang would
;; otherwise run the rest of the body with a half updated loop.  The check
;; reads compiled elisp, where the forms that pass a value through are few
;; and anything else, a call or a condition-case among them, is not one.
(defun cljbang--check-recur-tails (form tail)
  "Error when FORM holds a recur out of tail position.  TAIL if FORM is one."
  (when (consp form)
    (cond
     ((eq (car form) 'quote) nil)
     ((eq (car form) 'cljbang--recur)
      (unless tail
        (error "cljbang: recur is only allowed in tail position"))
      (dolist (f (cdr form)) (cljbang--check-recur-tails f nil)))
     ((eq (car form) 'progn)
      (cljbang--check-recur-body (cdr form) tail))
     ((eq (car form) 'if)
      (cljbang--check-recur-tails (cadr form) nil)
      (dolist (f (cddr form)) (cljbang--check-recur-tails f tail)))
     ((memq (car form) '(let let*))
      (dolist (binding (cadr form))
        (when (consp binding) (cljbang--check-recur-tails (cadr binding) nil)))
      (cljbang--check-recur-body (cddr form) tail))
     (t (dolist (f (cdr form)) (cljbang--check-recur-tails f nil))))))

(defun cljbang--check-recur-body (forms tail)
  "Check FORMS, where only the last is in tail position when TAIL."
  (while forms
    (cljbang--check-recur-tails (car forms) (and tail (null (cdr forms))))
    (setq forms (cdr forms))))

(defun cljbang--strip-recur-marks (form)
  "FORM with every recur mark rewritten to the progn it stands for."
  (cond ((not (consp form)) form)
        ((not (proper-list-p form)) form)
        ((eq (car form) 'quote) form)
        ((eq (car form) 'cljbang--recur)
         (cons 'progn (mapcar #'cljbang--strip-recur-marks (cdr form))))
        (t (mapcar #'cljbang--strip-recur-marks form))))

(defun cljbang--thread (init forms first?)
  "Expand -> (FIRST? t) or ->> threading."
  (let ((acc init))
    (dolist (f forms acc)
      (setq acc (cljbang--thread-1 f acc first?)))))

(defun cljbang--thread-1 (form acc first?)
  "Thread ACC into FORM, in first or last position."
  (cond ((not (consp form)) (list form acc))
        (first? (cons (car form) (cons acc (cdr form))))
        (t (append form (list acc)))))

;; each step binds its value, so the next step sees it and a nil stops
;; the chain without running what follows
(defun cljbang--some-thread (init forms first?)
  "Expand some-> (FIRST? t) or some->> threading."
  (if (null forms)
      init
    (let ((step (gensym "cljbang-some-")))
      (list 'let (vector step init)
            (list 'if step
                  (cljbang--some-thread
                   (cljbang--thread-1 (car forms) step first?)
                   (cdr forms) first?)
                  nil)))))


(defun cljbang--assign-target (sym env)
  "Elisp symbol SYM assigns to.  Unlike value position, it stays unevaluated."
  (unless (symbolp sym)
    (error "cljbang: set! needs a symbol, got %S" sym))
  (cond ((memq sym env) sym)
        ((cljbang--el-symbol sym))
        ((cljbang--ns-resolve sym))
        ((cljbang--qualified sym))
        (t sym)))

;; A macro is interned like a var, so it is namespaced by the same munge
;; and a macro of one namespace cannot be seen from another.  The expander
;; hangs off the symbol rather than its function cell, since it takes and
;; returns cljbang forms rather than elisp ones.

(defun cljbang--register-macro (sym expander)
  "Register EXPANDER as the macro named by the elisp symbol SYM."
  (put sym 'cljbang-macro expander)
  nil)

(defun cljbang--macro-function (sym)
  "Expander for SYM, resolved as any other name is, or nil.
Resolving first lets a macro of the namespace shadow one cljbang ships.
The bare symbol comes last, which finds one defined outside any namespace."
  (get (or (cljbang--resolve-name sym)
           (alist-get sym cljbang--core-macros)
           sym)
       'cljbang-macro))

(defun cljbang--resolve-name (sym)
  "The elisp symbol SYM names, or nil when nothing here names one.
Clojure's resolve, over elisp's flat symbols: el/ gives a host name, a
qualified one goes through the aliases, and a bare one is a var of the
current namespace or a core function.  A special form resolves to
nothing, as it does in Clojure, and so does a name cljbang never saw."
  (or (cljbang--el-symbol sym)
      (cljbang--qualified sym)
      (cljbang--ns-resolve sym)
      (alist-get sym cljbang--core-fns)))

(defun cljbang--compile-symbol (form env)
  "Compile FORM in value position."
  (cond ((memq form env) form)
        ;; a name may be a def as readily as a defn, so resolve it the
        ;; lisp-1 way rather than assuming #', which a core function can
        ;; take since it is always a function
        ((or (cljbang--el-symbol form)
             (cljbang--qualified form)
             (cljbang--ns-resolve form))
         `(cljbang--resolve ',(cljbang--resolve-name form)))
        ((alist-get form cljbang--core-fns)
         `#',(alist-get form cljbang--core-fns))
        (t `(cljbang--resolve ',form))))

(defun cljbang--interned-here-p (sym)
  "Whether SYM is a var cljbang interned, which may not be evaluated yet."
  (and (cljbang--interned-as sym) t))

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
      ('cljbang--syntax-quote (cljbang--compile-syntax-quote (cadr form) env))
      ((or 'cljbang--unquote 'cljbang--unquote-splicing)
       ;; either outside any syntax quote, or one deeper than the quotes,
       ;; as ~~x is under a single quote
       (error "cljbang: %s has no matching syntax quote"
              (if (eq (car form) 'cljbang--unquote) "~" "~@")))
      ('quote
       ;; a literal inside quoted data still has to be built, whichever
       ;; spelling of quote it hid behind
       (if (cljbang--holds-literal-p (cadr form))
           (cljbang-compile (cljbang--quote-literal (cadr form)) env)
         form))
      ('comment nil)
      ('require
       ;; specs are quoted, as in Clojure
       (let* ((specs (mapcar (lambda (arg)
                               (if (and (consp arg) (eq (car arg) 'quote))
                                   (cadr arg)
                                 arg))
                             (cdr form)))
              (loaded (mapcar #'cljbang--require-spec specs)))
         ;; the aliases are emitted too, so a cached load knows them and
         ;; evaluating a new form afterwards resolves the same names
         `(progn ,@(cljbang--emit-aliases specs)
                 ,@(mapcar (lambda (ns) `(cljbang-require ,ns))
                           (delq nil loaded))
                 nil)))
      ('ns
       (let* ((name (symbol-name (cadr form)))
              (cljbang--load-file-dir (or (cljbang--ns-root name)
                                          cljbang--load-file-dir)))
         (cljbang--set-current-ns name)
         ;; register (:require [lib :as alias]) clauses, which belong to
         ;; this namespace, so they are recorded after it is in effect
         (let (loaded specs)
           (dolist (clause (cddr form))
             (when (and (consp clause) (eq (car clause) :require))
               (dolist (spec (cdr clause))
                 (push spec specs)
                 (push (cljbang--require-spec spec) loaded))))
           ;; the loads and the aliases are emitted as well as run, so a
           ;; file restored from its cache pulls in what it requires and
           ;; resolves the same names afterwards
           `(progn (cljbang--set-current-ns ,name)
                   ,@(cljbang--emit-aliases (nreverse specs))
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
                    (`(,_doc ,tail) (cljbang--split-docstring rest))
                    (name* (cljbang--ns-intern name))
                    (fn (cljbang--compile-fn tail env)))
         ;; registered now, so the rest of this file can use it, and
         ;; emitted too, so a compiled file registers it again on load
         (cljbang--register-macro name* (eval fn t))
         `(progn (put ',name* 'cljbang-macro ,fn) ',name*)))
      ((or 'defn 'defn-)
       (pcase-let* ((`(,name . ,rest) (cdr form))
                    (`(,doc ,tail) (cljbang--split-docstring rest))
                    (name* (cljbang--ns-intern name (eq (car form) 'defn-)))
                    (fn (cljbang--compile-fn tail env)))
         ;; a docstring goes where elisp keeps one, so C-h f finds it
         (when doc (setq fn `(lambda ,(cadr fn) ,doc ,@(cddr fn))))
         `(progn (defalias ',name* ,fn) ',name*)))
      ('fn
       (let ((rest (cdr form)))
         (when (symbolp (car rest)) (pop rest)) ; drop optional fn name
         (cljbang--compile-fn rest env)))
      ('set!
       `(setq ,(cljbang--assign-target (cadr form) env)
              ,(cljbang-compile (caddr form) env)))
      ('let (cljbang--compile-let (cadr form) (cddr form) env))
      ('loop (cljbang--compile-loop (cadr form) (cddr form) env))
      ('recur (cljbang--compile-recur (cdr form) env))
      ('try (cljbang--compile-try (cdr form) env))
      ('if `(if ,@(cljbang--compile-body (cdr form) env)))
      ('do `(progn ,@(cljbang--compile-body (cdr form) env)))
      (_ (cljbang--compile-call form env))))))

;;; Entry point

(defun cljbang--read-forms (s)
  "Clojure source S as forms, ready for `cljbang-compile'."
  (cljbang--splice-braces (cljbang--read-all (cljbang--rewrite-dispatch s))))

;; edn is what a quoted literal already is, so the code reader does the
;; reading and the only work left is refusing what edn does not have.

(defconst cljbang--not-edn
  '((el/cljbang-deref . "@") (el/cljbang-re-pattern . "#\"")
    (cljbang--fn-literal . "#(") (cljbang--syntax-quote . "`")
    (cljbang--unquote . "~") (cljbang--unquote-splicing . "~@")
    (\` . "`") (\,@ . "~@"))
  "What the reader made of syntax that edn does not have.")

(defun cljbang--edn-form (form)
  "FORM with edn booleans as the host's, refusing what is not edn."
  (cond ((eq form 'true) t)
        ((eq form 'false) nil)
        ((vectorp form)
         (apply #'vector (mapcar #'cljbang--edn-form (append form nil))))
        ((consp form)
         (when-let* ((hit (assq (car form) cljbang--not-edn)))
           (error "cljbang: %s is not edn" (cdr hit)))
         (cons (cljbang--edn-form (car form)) (cljbang--edn-form (cdr form))))
        ;; the elisp reader turns #_ into the empty-named symbol
        ((and form (symbolp form) (string= "" (symbol-name form)))
         (error "cljbang: #_ is not supported"))
        (t form)))

(defun cljbang-edn-read-string (s)
  "Read the first edn form in S, as clojure.edn/read-string does.
false reads as nil, since the host has no false.  Char and tagged
literals are not supported."
  (let ((form (cljbang--edn-form (car (cljbang--read-forms (concat "'" s))))))
    (eval (cljbang-compile form) t)))

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

(defun cljbang--code-position-p (pos)
  "Whether POS is code rather than inside a string or a comment."
  (let ((state (save-excursion (syntax-ppss pos))))
    (not (or (nth 3 state) (nth 4 state)))))

(defun cljbang--escape-auto-gensyms ()
  "Escape the # ending an auto gensym name in the current buffer.
The elisp reader opens a dispatch on #, so x# has to reach it as x\\#.
Done before anything scans a sexp, so x# counts as the one symbol it is."
  (let (spots)
    (goto-char (point-min))
    (while (search-forward "#" nil t)
      (let ((beg (match-beginning 0)))
        (when (and (cljbang--code-position-p beg)
                   (> beg (point-min))
                   ;; inside a name, and ending it
                   (not (memq (char-before beg)
                              '(?\s ?\t ?\n ?\( ?\[ ?{ ?\) ?\] ?} ?# ?\' ?` ?~ ?@ ?, ?\")))
                   (memq (char-after (1+ beg))
                         '(?\s ?\t ?\n ?\) ?\] ?} nil)))
          (push beg spots))))
    ;; latest first, so the earlier positions stay valid
    (dolist (beg spots)
      (goto-char beg)
      (insert "\\"))))

(defun cljbang--wrap-next-sexp (prefix opener edits &optional sexp-at token-start
                                       not-before)
  "Add edits to EDITS wrapping the sexp after each PREFIX in OPENER.
SEXP-AT is where the sexp starts relative to PREFIX, its length by
default.  TOKEN-START limits the match to a prefix that opens a token,
which @ needs because an elisp symbol may contain one.  NOT-BEFORE skips
a match followed by that character, which is how ~ leaves ~@ alone."
  (let ((skip (or sexp-at (length prefix))))
    (goto-char (point-min))
    (while (search-forward prefix nil t)
      ;; syntax-ppss moves point, so keep the search position
      (let ((beg (match-beginning 0)))
        (when (and (cljbang--code-position-p beg)
                   (not (and not-before
                             (eq (char-after (+ beg (length prefix))) not-before)))
                   (or (not token-start)
                       (= beg (point-min))
                       ;; a quote or another @ opens a token as readily as
                       ;; a delimiter does, which is what `@x and @@x need.
                       ;; Not ~, whose @ belongs to the splice matched already
                       (memq (char-before beg)
                             '(?\s ?\t ?\n ?\( ?\[ ?{ ?` ?\' ?@))))
          (goto-char (+ beg skip))
          (when-let* ((end (ignore-errors
                             (save-excursion (forward-sexp) (point)))))
            (push (list end 0 ")") edits)
            (push (list beg (length prefix) opener) edits)
            ;; scan on inside the sexp, so a nested ` or @ is wrapped too
            (goto-char (+ beg (length prefix)))))))
    edits))

(defun cljbang--regex-body (body)
  "BODY of a regex literal, with the backslashes the reader eats put back.
A backslash stands for itself in a regex literal, as it does in Clojure,
so \\( is a group rather than a plain paren.  An escaped quote is left
alone, since the reader has to take that one away."
  (let ((out "") (i 0) (n (length body)))
    (while (< i n)
      (let ((c (aref body i)))
        (cond ((and (eq c ?\\) (< (1+ i) n) (eq (aref body (1+ i)) ?\"))
               (setq out (concat out "\\\"") i (+ i 2)))
              ((eq c ?\\)
               (setq out (concat out "\\\\") i (1+ i)))
              (t (setq out (concat out (char-to-string c))) (setq i (1+ i))))))
    out))

(defun cljbang--regex-edits (edits)
  "Add edits to EDITS turning each regex literal into a call."
  (goto-char (point-min))
  (while (search-forward "#\"" nil t)
    (let ((beg (match-beginning 0)))
      (when (cljbang--code-position-p beg)
        (goto-char (1+ beg))
        (when-let* ((end (ignore-errors (save-excursion (forward-sexp) (point)))))
          (push (list beg (- end beg)
                      (concat "(el/cljbang-re-pattern \""
                              (cljbang--regex-body
                               (buffer-substring-no-properties (+ beg 2) (1- end)))
                              "\")"))
                edits)
          (goto-char end)))))
  edits)

(defun cljbang--discard-forms ()
  "Delete each #_ and the form after it, the discard it is in Clojure.
Scanned backwards, so #_#_ discards two forms, innermost first."
  (goto-char (point-max))
  (while (search-backward "#_" nil t)
    (let ((beg (point)))
      (when (and (cljbang--code-position-p beg)
                 ;; opening a token, or stacked on another discard
                 (or (bobp)
                     (memq (char-before beg)
                           '(?\s ?\t ?\n ?\( ?\[ ?{ ?\) ?\] ?} ?` ?\' ?~ ?@ ?,))
                     (and (>= beg 3)
                          (string= "#_" (buffer-substring (- beg 2) beg)))))
        (goto-char (+ beg 2))
        (when-let* ((end (ignore-errors (save-excursion (forward-sexp) (point)))))
          (delete-region beg end)))
      (goto-char beg))))

(defun cljbang--rewrite-dispatch (s)
  "Rewrite the reader macros in S to forms the elisp reader accepts.
Occurrences inside a string or a comment are left alone.  Needs the
source text, so it applies to files and inline evaluation but not to
`clj!'."
  (with-temp-buffer
    (insert s)
    (let ((table (make-syntax-table)))
      (modify-syntax-entry ?\" "\"" table)
      (modify-syntax-entry ?\\ "\\" table)
      (modify-syntax-entry ?\; "<" table)
      (modify-syntax-entry ?\n ">" table)
      ;; braces are delimiters here, so scanning a sexp spans a map, even
      ;; though the elisp reader itself will need them spliced apart
      (modify-syntax-entry ?{ "(}" table)
      (modify-syntax-entry ?} "){" table)
      (set-syntax-table table))
    (cljbang--escape-auto-gensyms)
    (cljbang--discard-forms)
    (let (edits)
      (pcase-dolist (`(,find . ,replace) cljbang--dispatch-rewrites)
        (goto-char (point-min))
        (while (search-forward find nil t)
          (let ((beg (match-beginning 0)))
            (when (cljbang--code-position-p beg)
              (push (list beg (length find) replace) edits))
            (goto-char (+ beg (length find))))))
      ;; each of these takes two edits, an opener and a closing paren that
      ;; has to be found by scanning the sexp the reader macro applies to.
      ;; ~@ goes before ~, so the longer one wins the shared tilde.
      ;; el/ so that what the reader emits reaches the host function even
      ;; where a var of that name is defined
      (setq edits (cljbang--regex-edits edits))
      (setq edits (cljbang--wrap-next-sexp "`" "(cljbang--syntax-quote " edits))
      (setq edits (cljbang--wrap-next-sexp "~@" "(cljbang--unquote-splicing " edits))
      (setq edits (cljbang--wrap-next-sexp "~" "(cljbang--unquote " edits nil nil ?@))
      (setq edits (cljbang--wrap-next-sexp "@" "(el/cljbang-deref " edits nil t))
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

(defun cljbang--holds-literal-p (form)
  "Whether FORM holds a map or set literal anywhere."
  (cond ((consp form)
         (or (memq (car form) '(cljbang--map-literal cljbang--set-literal))
             (cljbang--holds-literal-p (car form))
             (cljbang--holds-literal-p (cdr form))))
        ((vectorp form)
         (cl-some #'cljbang--holds-literal-p (append form nil)))))

(defun cljbang--quote-literal (form)
  "Quote FORM as Clojure quotes a literal collection, element by element."
  (cond ((and (consp form)
              (memq (car form) '(cljbang--map-literal cljbang--set-literal)))
         (cons (car form) (mapcar #'cljbang--quote-literal (cdr form))))
        ((vectorp form)
         (apply #'vector (mapcar #'cljbang--quote-literal (append form nil))))
        ;; a list is rebuilt only when a literal hides in it, so an
        ;; ordinary quoted list stays the shared structure it was
        ((and (consp form) (cljbang--holds-literal-p form))
         (if (proper-list-p form)
             (cons 'list (mapcar #'cljbang--quote-literal form))
           (list 'cons (cljbang--quote-literal (car form))
                 (cljbang--quote-literal (cdr form)))))
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
            (push (if pending (progn (setq pending nil) (cljbang--quote-literal v)) v)
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

(defconst cljbang-version "0.0.7"
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
  (cljbang--with-ns (cljbang--current-ns)
   (let* ((file (expand-file-name file))
         (src (with-temp-buffer (insert-file-contents file) (buffer-string)))
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
    (cljbang--cache-file file))))

(defvar cljbang--file-value nil
  "Value of the last form of the file just loaded from a cache.")

(defun cljbang--load-file-uncached (file)
  "Compile and evaluate FILE without touching a cache."
  ;; an (ns ...) in the file takes effect during the load only, like
  ;; Clojure's load-file preserving the caller's *ns*
  (cljbang--with-ns (cljbang--current-ns)
    (let ((src (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
          ;; the root a :require resolves against is derived from the ns
          (cljbang--load-file-name (expand-file-name file))
          (cljbang--load-file-dir (file-name-directory (expand-file-name file))))
      (cljbang-eval-string src))))

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
 'cljbang-core->
 (lambda (init &rest forms) (cljbang--thread init forms t)))

(cljbang--register-macro
 'cljbang-core->>
 (lambda (init &rest forms) (cljbang--thread init forms nil)))

;; the constants are not evaluated, so they are quoted into the test.  A
;; list constant matches any of its elements, as it does in Clojure.
(defun cljbang--case (expr clauses)
  "Expansion of case over EXPR and CLAUSES, pairs then an optional default."
  (let ((val (gensym "cljbang-case-"))
        (default (when (cl-oddp (length clauses))
                   (car (last clauses))))
        (pairs (if (cl-oddp (length clauses)) (butlast clauses) clauses))
        tests)
    (while pairs
      (let ((const (pop pairs))
            (result (pop pairs)))
        (push (list (if (consp const)
                        (list 'contains? (cons 'hash-set
                                               (mapcar (lambda (c) (list 'quote c)) const))
                              val)
                      (list '= val (list 'quote const)))
                    result)
              tests)))
    (list 'let (vector val expr)
          (cons 'cond
                (append (apply #'append (nreverse tests))
                        (list :else
                              (or default
                                  (list 'throw
                                        (list 'ex-info "No matching clause"
                                              (list 'cljbang--map-literal
                                                    :value val))))))))))

(cljbang--register-macro
 'cljbang-core-case
 (lambda (expr &rest clauses) (cljbang--case expr clauses)))

(cljbang--register-macro
 'cljbang-core-some->
 (lambda (init &rest forms) (cljbang--some-thread init forms t)))

(cljbang--register-macro
 'cljbang-core-some->>
 (lambda (init &rest forms) (cljbang--some-thread init forms nil)))

(cljbang--register-macro
 'cljbang-core-when
 (lambda (test &rest body) (list 'if test (cons 'do body))))

(cljbang--register-macro
 'cljbang-core-cond
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
 'cljbang-core-if-let
 (lambda (binding then &optional else) (cljbang--if-let binding then else)))

(cljbang--register-macro
 'cljbang-core-when-let
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
 'cljbang-core-doseq
 (lambda (bindings &rest body) (cljbang--doseq bindings body)))

(cljbang--register-macro
 'cljbang-core-dotimes
 (lambda (binding &rest body) (cljbang--dotimes binding body)))

(cljbang--register-macro
 'cljbang-core-with-out-str
 (lambda (&rest body) (cons 'el/with-output-to-string body)))

(cljbang--register-macro
 'cljbang-core-time
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
  ;; an (ns ...) in the file takes effect during the load only, whether it
  ;; ran now or was baked into the cache
  (cljbang--with-ns (cljbang--current-ns)
   (let* ((file (expand-file-name file))
         (cache (cljbang--cache-file file))
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
      cljbang--file-value)))))



(provide 'cljbang)
;;; cljbang.el ends here