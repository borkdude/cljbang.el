;;; test-inline-eval.el --- eval-inside-clj! context test -*- lexical-binding: t; -*-

(add-to-list 'load-path (file-name-directory load-file-name))
(require 'clj2el-core)

(with-temp-buffer
  (emacs-lisp-mode)
  (insert "(clj!\n  (defn tri [x] (/ (* x (inc x)) 2))\n  (tri 10))\n")
  ;; Eval the inner defn as Clojure: point right after its closing paren.
  (goto-char (point-min))
  (search-forward "2))")
  (clj2el-eval-last-sexp)
  ;; Eval the inner call.
  (search-forward "(tri 10)")
  (clj2el-eval-last-sexp)
  ;; map literals work interactively
  ;; even though the elisp reader could never load them.
  (goto-char (point-max))
  (insert "(clj! (get {:a 41} :a))\n")
  (search-backward " :a)")
  (forward-char 4)
  (clj2el-eval-last-sexp)
  ;; Outside any clj! form: falls back to plain elisp eval.
  (goto-char (point-max))
  (insert "(concat \"el\" \"isp\")\n")
  (goto-char (1- (point-max)))
  (clj2el-eval-last-sexp))
