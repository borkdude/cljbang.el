;;; bench-load.el --- what loading costs, source vs byte-compiled -*- lexical-binding: t; -*-

;;; Commentary:

;; Three ways to get 1000 defns into Emacs: compile .clj source at load,
;; load a byte-compiled file that used clj!, and load plain elisp.

;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'cljbang)

(defvar bench-load--dir (make-temp-file "cljbang-bench" t))

(defmacro bench-load--ms (label &rest body)
  `(let ((start (current-time)))
     ,@body
     (message "  %-40s %7.2f ms" ,label
              (* 1000 (float-time (time-subtract (current-time) start))))))

(defun bench-load--sources (n)
  "Write the three equivalent sources for N defns, and return their names."
  (let ((clj (mapconcat
              (lambda (i)
                (format "(defn cf%d [x] (let [y (+ x %d)] (if (odd? y) (* y 2) (-> y (+ 1) (* 3)))))" i i))
              (number-sequence 0 (1- n)) "\n"))
        (el (mapconcat
             (lambda (i)
               (format "(defun ef%d (x) (let* ((y (+ x %d))) (if (cl-oddp y) (* y 2) (* (+ y 1) 3))))" i i))
             (number-sequence 0 (1- n)) "\n"))
        (clj-file (expand-file-name "gen.clj" bench-load--dir))
        (macro-file (expand-file-name "viaclj.el" bench-load--dir))
        (plain-file (expand-file-name "plain.el" bench-load--dir)))
    (write-region clj nil clj-file nil 'quiet)
    (write-region (concat ";;; -*- lexical-binding: t -*-\n(require 'cljbang)\n(clj! "
                          clj ")\n(provide 'viaclj)\n")
                  nil macro-file nil 'quiet)
    (write-region (concat ";;; -*- lexical-binding: t -*-\n(require 'cl-lib)\n"
                          el "\n(provide 'plain)\n")
                  nil plain-file nil 'quiet)
    (list clj-file macro-file plain-file)))

(let* ((n 1000)
       (files (bench-load--sources n)))
  (message "loading %d defns" n)
  (byte-compile-file (nth 1 files))
  (byte-compile-file (nth 2 files))
  (bench-load--ms ".clj source, compiled every load"
                  (cljbang-load-file (nth 0 files)))
  (bench-load--ms "byte-compiled .el using clj!"
                  (load (concat (nth 1 files) "c") nil t))
  (bench-load--ms "byte-compiled plain elisp"
                  (load (concat (nth 2 files) "c") nil t)))

(delete-directory bench-load--dir t)

;;; bench-load.el ends here
