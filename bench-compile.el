;;; bench-compile.el --- clj pipeline vs direct elisp, one large namespace -*- lexical-binding: t; -*-

(add-to-list 'load-path (file-name-directory load-file-name))
(require 'clj2el-core)

(defmacro bench--ms (&rest body)
  `(let ((bench--start (current-time)))
     ,@body
     (* 1000 (float-time (time-subtract (current-time) bench--start)))))

;; Equivalent bodies: let + arithmetic + branch + threading.
(defun bench--clj-src (n)
  (mapconcat
   (lambda (i)
     (format "(defn cf%d [x] (let [y (+ x %d)] (if (odd? y) (* y 2) (-> y (+ 1) (* 3)))))"
             i i))
   (number-sequence 0 (1- n)) "\n"))

(defun bench--el-src (n)
  (mapconcat
   (lambda (i)
     (format "(defun ef%d (x) (let* ((y (+ x %d))) (if (cl-oddp y) (* y 2) (* (+ y 1) 3))))"
             i i))
   (number-sequence 0 (1- n)) "\n"))

(defun bench--read-all (src)
  (let ((pos 0) forms)
    (while (< pos (length src))
      (pcase-let ((`(,form . ,next) (read-from-string src pos)))
        (push form forms)
        (setq pos next)))
    (nreverse forms)))

(let* ((n 1000)
       (clj-src (bench--clj-src n))
       (macro-src (string-replace "defn cf" "defn mf" clj-src))
       (el-src (bench--el-src n))
       forms compiled el-forms macro-forms expansion
       ;; string pipeline: source text in, values out
       (t-parse (bench--ms
                 (setq forms (clj2el--splice-braces (clj2el--read-all clj-src)))))
       (t-compile (bench--ms (setq compiled (mapcar #'clj2el-compile forms))))
       (t-eval (bench--ms (dolist (f compiled) (eval f t))))
       ;; clj! macro path: forms already read by the elisp reader
       (t-m-read (bench--ms (setq macro-forms (bench--read-all macro-src))))
       (t-m-compile (bench--ms (setq expansion (macroexpand-1 (cons 'clj! macro-forms)))))
       (t-m-eval (bench--ms (eval expansion t)))
       ;; direct elisp
       (t-read (bench--ms (setq el-forms (bench--read-all el-src))))
       (t-el-eval (bench--ms (dolist (f el-forms) (eval f t))))
       ;; run: all three produce plain elisp closures
       (t-run-clj (bench--ms (dotimes (i n) (funcall (intern (format "cf%d" i)) 42))))
       (t-run-m (bench--ms (dotimes (i n) (funcall (intern (format "mf%d" i)) 42))))
       (t-run-el (bench--ms (dotimes (i n) (funcall (intern (format "ef%d" i)) 42)))))
  (message "namespace of %d defns (%d KB clj / %d KB el source)"
           n (/ (length clj-src) 1024) (/ (length el-src) 1024))
  (message "")
  (message "string pipeline:")
  (message "  read              %8.2f ms" t-parse)
  (message "  compile           %8.2f ms" t-compile)
  (message "  eval              %8.2f ms" t-eval)
  (message "  TOTAL             %8.2f ms" (+ t-parse t-compile t-eval))
  (message "")
  (message "clj! macro path:")
  (message "  read              %8.2f ms" t-m-read)
  (message "  compile           %8.2f ms" t-m-compile)
  (message "  eval              %8.2f ms" t-m-eval)
  (message "  TOTAL             %8.2f ms" (+ t-m-read t-m-compile t-m-eval))
  (message "")
  (message "direct elisp:")
  (message "  read              %8.2f ms" t-read)
  (message "  eval              %8.2f ms" t-el-eval)
  (message "  TOTAL             %8.2f ms" (+ t-read t-el-eval))
  (message "")
  (message "run all %d fns:  string %.2f ms | clj! %.2f ms | elisp %.2f ms"
           n t-run-clj t-run-m t-run-el)
  ;; sanity: same answers from all three
  (dolist (i (number-sequence 0 9))
    (let ((c (funcall (intern (format "cf%d" i)) 42))
          (m (funcall (intern (format "mf%d" i)) 42))
          (e (funcall (intern (format "ef%d" i)) 42)))
      (unless (and (equal c m) (equal c e))
        (error "MISMATCH at %d: clj=%S macro=%S el=%S" i c m e)))))
