;;; test-filemode.el --- file-local activation + result overlays -*- lexical-binding: t; -*-

;; Self-contained: writes its own .clj file to a temp dir so it never
;; conflicts with (or mutates) files the user has open.

(add-to-list 'load-path (file-name-directory load-file-name))
(require 'clj2el-core)

(defun test--overlay-text ()
  (mapconcat (lambda (ov) (overlay-get ov 'after-string))
             clj2el--result-overlays ""))

(let* ((dir (make-temp-file "clj2el-test" t))
       (file (expand-file-name "sample.clj" dir)))
  (with-temp-file file
    (insert ";; -*- mode: clojure; clj2el-whole-buffer: t -*-\n"
            "(ns my-test-file\n"
            "  (:require [clojure.string :as str]))\n"
            "\n"
            "(defn foobar [x] (str/join \",\" [1 2 3]))\n"
            "\n"
            "(emacs-version)\n"))
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (message "clj2el-mode enabled: %s" (if clj2el-mode "yes" "no"))
      (message "whole-buffer flag:   %S" clj2el-whole-buffer)
      ;; eval the defn (whole buffer is Clojure context, no clj! wrapper)
      (goto-char (point-min))
      (search-forward "[1 2 3]))")
      (clj2el-eval-last-sexp)
      (message "overlay after defn:  %S" (test--overlay-text))
      (message "my-test-file--foobar fbound: %s" (fboundp 'my-test-file--foobar))
      ;; eval the (emacs-version) elisp interop call
      (goto-char (point-min))
      (search-forward "(emacs-version)")
      (clj2el-eval-last-sexp)
      (message "interop overlay starts with \" => GNU Emacs\": %s"
               (if (string-prefix-p " => GNU Emacs" (test--overlay-text))
                   "yes" "no"))
      ;; previous overlay was replaced; pre-command-hook clears
      (message "overlay count: %d" (length clj2el--result-overlays))
      (clj2el--remove-result-overlays)
      (message "after simulated next command: %d overlays"
               (length clj2el--result-overlays))
      ;; call through the aliased require + subs
      (goto-char (point-max))
      (insert "\n(subs (foobar 1) 0 3)\n")
      (goto-char (1- (point-max)))
      (clj2el-eval-last-sexp)
      (message "overlay after call: %S" (test--overlay-text))
      (set-buffer-modified-p nil))
    (kill-buffer buf))
  (delete-directory dir t))
