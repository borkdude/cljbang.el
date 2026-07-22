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

;;; Namespace state
;;
;; One table holds it all: :current names the namespace being compiled or
;; loaded, and every namespace name keys the aliases and vars declared in
;; it.  Aliases belong to a namespace, as they do in Clojure, so one file
;; cannot see what another one required.  A compiled file sets the current
;; namespace when it loads, so this lives here rather than in the compiler.

(defvar cljbang--ns-state (make-hash-table :test #'equal)
  "Namespace name -> its state, and :current -> the namespace in effect.")

(defconst cljbang--no-ns :none
  "Key for the state of code outside any namespace.")

(defun cljbang--current-ns ()
  "Name of the namespace in effect, or nil outside one."
  (gethash :current cljbang--ns-state))

(defun cljbang--set-current-ns (ns)
  (puthash :current ns cljbang--ns-state))

(defun cljbang--ns-entry (&optional ns)
  "State of NS, the current namespace by default, created when missing."
  (let ((key (or ns (cljbang--current-ns) cljbang--no-ns)))
    (or (gethash key cljbang--ns-state)
        (puthash key
                 (list :aliases nil :vars (make-hash-table :test #'equal))
                 cljbang--ns-state))))

(defun cljbang--ns-aliases (&optional ns)
  (plist-get (cljbang--ns-entry ns) :aliases))

(defun cljbang--ns-add-alias (alias name)
  "Record ALIAS for namespace NAME in the current namespace."
  (let ((entry (cljbang--ns-entry)))
    (setf (alist-get alias (plist-get entry :aliases)) name)))

(defun cljbang--ns-var-table (&optional ns)
  (plist-get (cljbang--ns-entry ns) :vars))

;; Munging is not reversible: (ns a-b) with c and (ns a) with b-c both
;; intern a-b-c.  An index of what each symbol was interned as makes the
;; second definition warn rather than replace the first in silence.

(defun cljbang--interned-table ()
  "Interned symbol -> the (NAMESPACE . NAME) it was interned as."
  (or (gethash :interned cljbang--ns-state)
      (puthash :interned (make-hash-table :test #'eq) cljbang--ns-state)))

(defun cljbang--interned-as (sym)
  "The (NAMESPACE . NAME) SYM was interned as, or nil."
  (gethash sym (cljbang--interned-table)))

(defmacro cljbang--with-ns (ns &rest body)
  "Run BODY with NS as the current namespace, restoring it afterwards."
  (declare (indent 1))
  (let ((saved (gensym "cljbang-ns-")))
    `(let ((,saved (cljbang--current-ns)))
       (unwind-protect
           (progn (cljbang--set-current-ns ,ns) ,@body)
         (cljbang--set-current-ns ,saved)))))

(defun cljbang-first (coll)
  (if (seq-empty-p coll) nil (seq-elt coll 0)))

(defun cljbang-rest (coll)
  (seq-into (seq-drop coll 1) 'list))

(defun cljbang-second (coll)
  (cljbang-first (cljbang-rest coll)))

(defun cljbang-last (coll)
  "The last element of COLL.  Elisp's last gives the last cons cell."
  (let ((n (cljbang-count coll)))
    (unless (zerop n) (seq-elt coll (1- n)))))

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

(defun cljbang-remove (pred coll)
  (seq-remove (cljbang--fn pred) (seq-into coll 'list)))

(defun cljbang-reduce (f init coll)
  (seq-reduce (cljbang--fn f) (seq-into coll 'list) init))

(defun cljbang-concat (&rest colls)
  "Concatenate COLLS into a list.  Elisp's concat would give a string."
  (apply #'append (mapcar (lambda (c) (append c nil)) colls)))

(defun cljbang--compare-lt (a b)
  "Whether A sorts before B, over the types Clojure's compare handles."
  (cond ((and (numberp a) (numberp b)) (< a b))
        ((and (stringp a) (stringp b)) (string< a b))
        ((and (symbolp a) (symbolp b)) (string< a b))
        (t (error "cljbang: cannot compare %S and %S" a b))))

(defun cljbang-sort (comp &optional coll)
  "Sort COLL, by COMP when given.  Copies, since elisp's sort is destructive."
  (unless coll (setq coll comp comp nil))
  (sort (append coll nil) (if comp (cljbang--fn comp) #'cljbang--compare-lt)))

(defun cljbang-count (coll)
  (cond ((cljbang--set-p coll) (hash-table-count (cljbang--set-table coll)))
        ((hash-table-p coll) (hash-table-count coll))
        (t (seq-length coll))))

;; A set is its own record over a hash table, not a bare one, so a map
;; can be told from a set.  Elisp has no set type to interoperate with,
;; so nothing is lost by making it opaque.

(defun cljbang--set-p (x)
  (and (recordp x) (eq (aref x 0) 'cljbang-set)))

(defun cljbang--set-table (x) (aref x 1))

(defun cljbang-conj (coll x)
  (cond ((vectorp coll) (vconcat coll (vector x)))
        ((cljbang--set-p coll)
         (let ((h (copy-hash-table (cljbang--set-table coll))))
           (puthash x x h)
           (record 'cljbang-set h)))
        ((hash-table-p coll)
         ;; a map takes a [k v] pair or another map, as in Clojure
         (cond ((and (vectorp x) (= 2 (length x)))
                (cljbang-assoc coll (aref x 0) (aref x 1)))
               ((hash-table-p x) (cljbang-merge coll x))
               (t (error "cljbang: cannot conj %S onto a map" x))))
        (t (cons x coll))))

;; Clojure throws a value and catches that same value back.  Elisp signals
;; an error symbol with data, so a thrown value rides along as the data of
;; cljbang-error, and catch unwraps it.  A native elisp error is bound as
;; it comes, the way a Clojure catch of an NPE binds an NPE.

(define-error 'cljbang-error "cljbang throw")

(defun cljbang-throw (x)
  (signal 'cljbang-error (list x)))

(defun cljbang--caught (err)
  "What a catch clause binds for elisp error ERR."
  (if (eq (car-safe err) 'cljbang-error) (cadr err) err))

(defun cljbang-ex-info (msg data &optional cause)
  (record 'cljbang-ex-info msg data cause))

(defun cljbang--ex-info-p (x)
  (and (recordp x) (eq (aref x 0) 'cljbang-ex-info)))

(defun cljbang-ex-message (e)
  "Message of E, an ex-info or an elisp error, else nil as in Clojure."
  (cond ((cljbang--ex-info-p e) (aref e 1))
        ((and (consp e) (symbolp (car e))) (error-message-string e))))

(defun cljbang-ex-data (e)
  "Data of E when it is an ex-info, else nil as in Clojure."
  (when (cljbang--ex-info-p e) (aref e 2)))

(defun cljbang-ex-cause (e)
  (when (cljbang--ex-info-p e) (aref e 3)))

(defun cljbang-slurp (f)
  "Contents of file F as a string."
  (with-temp-buffer
    (insert-file-contents f)
    (buffer-string)))

(defun cljbang-spit (f content &rest opts)
  "Write CONTENT to file F, rendered as str renders it.
:append true appends instead of overwriting."
  (write-region (cljbang-str content) nil f
                (and (plist-get opts :append) t) 'quiet)
  nil)

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

;;; Sequences

(defun cljbang--list (coll)
  "COLL as a list, taking a map as its keys and values in pairs."
  (cond ((cljbang--set-p coll)
         (hash-table-keys (cljbang--set-table coll)))
        ((hash-table-p coll)
         (let (pairs)
           (maphash (lambda (k v) (push (vector k v) pairs)) coll)
           (nreverse pairs)))
        (t (seq-into coll 'list))))

(defun cljbang-seq (coll)
  "COLL as a list, or nil when it is empty, as in Clojure."
  (let ((l (cljbang--list coll)))
    (and l l)))

(defun cljbang-vec (coll) (seq-into (cljbang--list coll) 'vector))

(defun cljbang-set (coll)
  "Set of the elements of COLL."
  (apply #'cljbang-hash-set (cljbang--list coll)))

(defun cljbang-mapv (f coll)
  (seq-into (cljbang-map f coll) 'vector))

(defun cljbang-mapcat (f coll)
  (apply #'cljbang-concat (cljbang-map f coll)))

(defun cljbang-take (n coll)
  (seq-take (cljbang--list coll) (max n 0)))

(defun cljbang-drop (n coll)
  (seq-drop (cljbang--list coll) (max n 0)))

(defun cljbang-take-while (pred coll)
  (seq-take-while (cljbang--fn pred) (cljbang--list coll)))

(defun cljbang-drop-while (pred coll)
  (seq-drop-while (cljbang--fn pred) (cljbang--list coll)))

(defun cljbang-distinct (coll)
  (delete-dups (cljbang--list coll)))

(defun cljbang-some (pred coll)
  "The first truthy (PRED x) over COLL, else nil."
  (let ((f (cljbang--fn pred)))
    (catch 'cljbang--some
      (dolist (x (cljbang--list coll))
        (let ((v (funcall f x)))
          (when v (throw 'cljbang--some v)))))))

(defun cljbang-every? (pred coll)
  (and (seq-every-p (cljbang--fn pred) (cljbang--list coll)) t))

(defun cljbang-sort-by (keyfn comp &optional coll)
  "Sort COLL by KEYFN, comparing with COMP when given."
  (unless coll (setq coll comp comp nil))
  (let ((key (cljbang--fn keyfn))
        (lt (if comp (cljbang--fn comp) #'cljbang--compare-lt)))
    (sort (append coll nil)
          (lambda (a b) (funcall lt (funcall key a) (funcall key b))))))

(defun cljbang-range (&rest args)
  "Integers from START to END by STEP, as in Clojure."
  (let* ((start (if (cdr args) (car args) 0))
         (end (if (cdr args) (cadr args) (car args)))
         (step (or (caddr args) 1))
         acc)
    (if (> step 0)
        (while (< start end) (push start acc) (setq start (+ start step)))
      (while (> start end) (push start acc) (setq start (+ start step))))
    (nreverse acc)))

(defun cljbang-into (to from)
  (seq-reduce #'cljbang-conj (cljbang--list from) to))

(defun cljbang-empty? (coll)
  (zerop (cljbang-count coll)))

(defun cljbang-apply (f &rest args)
  "Call F with ARGS, the last of which is a collection, as in Clojure."
  (apply #'cljbang--invoke f
         (append (butlast args) (cljbang--list (car (last args))))))

;;; Maps

(defun cljbang-keys (m)
  (cond ((hash-table-p m) (hash-table-keys m))
        ((consp m) (mapcar #'car m))))

(defun cljbang-vals (m)
  (cond ((hash-table-p m) (hash-table-values m))
        ((consp m) (mapcar #'cdr m))))

(defun cljbang-merge (&rest ms)
  (let ((out (make-hash-table :test #'equal)))
    (dolist (m ms out)
      (when m (maphash (lambda (k v) (puthash k v out)) m)))))

(defun cljbang-dissoc (m &rest ks)
  (let ((h (copy-hash-table m)))
    (dolist (k ks h) (remhash k h))))

(defun cljbang-select-keys (m ks)
  (let ((h (make-hash-table :test #'equal)))
    (dolist (k (cljbang--list ks) h)
      (when (cljbang-contains? m k) (puthash k (cljbang-get m k) h)))))

(defun cljbang-update (m k f &rest args)
  (cljbang-assoc m k (apply #'cljbang--invoke f (cljbang-get m k) args)))

(defun cljbang-get-in (m path &optional default)
  (let ((v m))
    (catch 'cljbang--missing
      (dolist (k (cljbang--list path) v)
        (unless (cljbang-contains? v k) (throw 'cljbang--missing default))
        (setq v (cljbang-get v k))))))

(defun cljbang-assoc-in (m path v)
  (let ((ks (cljbang--list path)))
    (if (null (cdr ks))
        (cljbang-assoc m (car ks) v)
      (cljbang-assoc m (car ks)
                     (cljbang-assoc-in (or (cljbang-get m (car ks))
                                           (make-hash-table :test #'equal))
                                       (cdr ks) v)))))

(defun cljbang-update-in (m path f &rest args)
  (cljbang-assoc-in m path (apply #'cljbang--invoke f (cljbang-get-in m path) args)))

;;; Functions

(defun cljbang-partial (f &rest bound)
  (lambda (&rest args) (apply #'cljbang--invoke f (append bound args))))

(defun cljbang-comp (&rest fs)
  (if (null fs)
      #'identity
    (let ((fs (reverse fs)))
      (lambda (&rest args)
        (let ((v (apply #'cljbang--invoke (car fs) args)))
          (dolist (f (cdr fs) v)
            (setq v (cljbang--invoke f v))))))))

(defun cljbang-complement (f)
  (lambda (&rest args) (not (apply #'cljbang--invoke f args))))

(defun cljbang-constantly (x) (lambda (&rest _) x))

;;; Atoms

(defun cljbang-atom (x) (record 'cljbang-atom x))

(defun cljbang-deref (a)
  (if (and (recordp a) (eq (aref a 0) 'cljbang-atom)) (aref a 1) a))

(defun cljbang-reset! (a v) (aset a 1 v) v)

(defun cljbang-swap! (a f &rest args)
  (aset a 1 (apply #'cljbang--invoke f (aref a 1) args))
  (aref a 1))

;;; Predicates

(defun cljbang-keyword (x) (intern (concat ":" (cljbang-name x))))
(defun cljbang-symbol (x) (intern (cljbang-name x)))
(defun cljbang-nil? (x) (null x))
(defun cljbang-some? (x) (not (null x)))
(defun cljbang-map? (x) (hash-table-p x))
(defun cljbang-set? (x) (cljbang--set-p x))
(defun cljbang-fn? (x) (functionp x))

(defun cljbang-symbol? (x)
  "Whether X is a symbol.  A keyword is one in elisp, but not in Clojure."
  (and (symbolp x) (not (keywordp x)) (not (null x)) (not (eq x t))))

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
  "Set of XS."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (x xs) (puthash x x h))
    (record 'cljbang-set h)))

(defun cljbang-get (m k &optional default)
  "Look K up in M, which may be a map, a vector, or an elisp alist or plist.
Reading native elisp data matters because destructuring goes through here."
  (cond ((cljbang--set-p m) (gethash k (cljbang--set-table m) default))
        ((hash-table-p m) (gethash k m default))
        ((vectorp m) (if (and (integerp k) (>= k 0) (< k (length m)))
                         (aref m k)
                       default))
        ((null m) default)
        ;; An alist reads as a map, which is what Emacs passes around:
        ;; auto-mode-alist and a hundred others.  A plist does not, since
        ;; every list of keywords would look like one.  A key present
        ;; with a nil value is not the same as an absent key, so ask
        ;; whether the entry exists rather than what it returned.
        ((consp (car m))
         (let ((cell (assoc k m)))
           (if cell (cdr cell) default)))
        (t default)))

(defun cljbang--invoke (f &rest args)
  "Call F as Clojure does.
Sets, maps and vectors look their argument up.  A keyword looks itself
up in its argument.  Checking functionp first keeps byte-code objects,
which are vector-like, out of the lookup branches."
  (cond ((functionp f) (apply f args))
        ((or (hash-table-p f) (vectorp f) (cljbang--set-p f))
         (apply #'cljbang-get f args))
        ((keywordp f) (apply #'cljbang-get (car args) f (cdr args)))
        (t (apply f args))))

(defun cljbang-contains? (coll k)
  "Whether COLL has key K.  For a vector K is an index, as in Clojure."
  (cond ((cljbang--set-p coll)
         (not (eq 'cljbang--absent
                  (gethash k (cljbang--set-table coll) 'cljbang--absent))))
        ((hash-table-p coll)
         (not (eq 'cljbang--absent (gethash k coll 'cljbang--absent))))
        ((vectorp coll) (and (integerp k) (>= k 0) (< k (length coll))))
        ((null coll) nil)
        ((consp (car coll)) (and (assoc k coll) t))
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
   ((and (cljbang--set-p a) (cljbang--set-p b))
    (let ((ta (cljbang--set-table a))
          (tb (cljbang--set-table b)))
      (and (= (hash-table-count ta) (hash-table-count tb))
           (catch 'cljbang--unequal
             (maphash (lambda (k _)
                        (when (eq 'cljbang--absent
                                  (gethash k tb 'cljbang--absent))
                          (throw 'cljbang--unequal nil)))
                      ta)
             t))))
   ((or (cljbang--set-p a) (cljbang--set-p b)) nil)
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
          ((cljbang--set-p x)
           (concat "#{"
                   (mapconcat rec (hash-table-keys (cljbang--set-table x)) " ")
                   "}"))
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
