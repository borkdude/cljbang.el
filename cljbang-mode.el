;;; cljbang-mode.el --- Editing and evaluating cljbang -*- lexical-binding: t; -*-

;;; Commentary:

;; Inline evaluation, result overlays and completion.  Optional: cljbang
;; compiles and runs without any of this.

;;; Code:

(require 'subr-x)
(require 'cljbang)


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

(defgroup cljbang nil
  "Clojure that runs as Emacs Lisp."
  :group 'languages
  :prefix "cljbang-")

(defface cljbang-result-face
  '((t :inherit shadow :slant italic))
  "Face for inline evaluation result overlays."
  :group 'cljbang)

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
      ;; heed the nearest preceding (ns ...) form in the buffer
      (cljbang--with-ns (or (cljbang--buffer-ns) (cljbang--current-ns))
        (let* ((beg (save-excursion (backward-sexp) (point)))
               (val (cljbang-pr-str
                     (cljbang-eval-string
                      (buffer-substring-no-properties beg (point))))))
          (cljbang--show-result val (point))
          (message "=> %s" val)))
    (call-interactively #'eval-last-sexp)))

(defun cljbang--buffer-ns ()
  "Name of the nearest (ns ...) form before point, or nil."
  (save-excursion
    (when (re-search-backward "(ns[ \t\n]+\\([a-zA-Z0-9._-]+\\)" nil t)
      (match-string-no-properties 1))))

;;; Completion: Clojure names + all of elisp, via completion-at-point

(defun cljbang--completion-candidates ()
  "Clojure-side completion candidates: special forms, core fns, ns/aliased vars."
  (let ((cands (copy-sequence cljbang--special-forms)))
    (dolist (c cljbang--core-fns)
      (push (symbol-name (car c)) cands))
    (dolist (a (append (cljbang--ns-aliases (cljbang--buffer-ns))
                       cljbang--ns-default-aliases))
      (let ((prefix (concat (cdr a) "/")))
        (dolist (f cljbang--ns-fns)
          (when (string-prefix-p prefix (car f))
            (push (concat (symbol-name (car a)) "/"
                          (substring (car f) (length prefix)))
                  cands)))))
    (when-let* ((ns (or (cljbang--buffer-ns) (cljbang--current-ns))))
      (maphash (lambda (k _) (push k cands)) (cljbang--ns-var-table ns)))
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


(provide 'cljbang-mode)
;;; cljbang-mode.el ends here
