;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((emacs-lisp-mode
  (buffer-save-without-query . t)
  (indent-tabs-mode . nil)
  (eval . (flycheck-mode))
  (eval . (checkdoc-minor-mode))
  (bug-reference-url-format . "https://github.com/clojure-emacs/parseedn/issues/%s")
  (bug-reference-bug-regexp . "#\\(?2:[[:digit:]]+\\)")
  (fill-column . 80)
  (sentence-end-double-space . t)
  (emacs-lisp-docstring-fill-column . 75)
  (checkdoc-symbol-words . ("top-level" "major-mode" "macroexpand-all" "print-level" "print-length"))
  (checkdoc-package-keywords-flag)
  (checkdoc-arguments-in-order-flag)
  (checkdoc-verb-check-experimental-flag)
  (elisp-lint-indent-specs . ((if-let* . 2)
                              (when-let* . 1)
                              (let* . defun)
                              (nrepl-dbind-response . 2)
                              ;; need better solution for indenting cl-flet bindings
                              (insert-label . defun)              ;; cl-flet
                              (insert-align-label . defun)        ;; cl-flet
                              (insert-rect . defun)               ;; cl-flet
                              (cl-defun . 2)
                              (with-parsed-tramp-file-name . 2)
                              (thread-first . 0)
                              (thread-last . 0)
                              (transient-define-prefix . defmacro)
                              (transient-define-suffix . defmacro)))))

;; To use the bug-reference stuff, do:
;;     (add-hook 'text-mode-hook #'bug-reference-mode)
;;     (add-hook 'prog-mode-hook #'bug-reference-prog-mode)
