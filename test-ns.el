;;; test-ns.el --- ns form + munged interning + ns-aware inline eval -*- lexical-binding: t; -*-

(add-to-list 'load-path (file-name-directory load-file-name))
(require 'clj2el-core)

(let ((default-directory (file-name-directory load-file-name)))
  ;; test-file.clj is a scratch file, only assert that it loads
  (eval '(clj! (load-file "test-file.clj")) t)
  (message "test-file.clj loaded")
  (eval '(clj! (load-file "examples/nsdemo.clj")) t))

(message "foo--foobar fbound: %s" (fboundp 'foo--foobar))
(message "foo--baz fbound:    %s" (fboundp 'foo--baz))
(message "ns restored after load: %S" clj2el--current-ns)

;; qualified access from outside the ns
(eval '(clj! (println "foo/baz 10 =>" (foo/baz 10))) t)

;; plain elisp sees the munged names
(message "elisp (foo--baz 5): %s" (foo--baz 5))

;; inline eval heeds the buffer's (ns ...) form
(with-temp-buffer
  (emacs-lisp-mode)
  (insert "(clj!\n (ns foo)\n (foobar 7))\n")
  (goto-char (point-min))
  (search-forward "(foobar 7)")
  (clj2el-eval-last-sexp))
(message "ns still restored: %S" clj2el--current-ns)
