;;; cljbang-string.el --- clojure.string for cljbang -*- lexical-binding: t; -*-

;;; Commentary:

;; clojure.string, aliased to str out of the box.  Most of it is an elisp
;; builtin under another name, so only the ones whose semantics differ
;; need a wrapper.

;;; Code:

(require 'seq)
(require 'cljbang-core)

(defun cljbang-string-join (sep-or-coll &optional coll)
  (let ((sep (if coll sep-or-coll ""))
        (xs (seq-into (or coll sep-or-coll) 'list)))
    (mapconcat #'cljbang-str xs sep)))

(defun cljbang-string-split (s re)
  (apply #'vector (split-string s re)))

(defun cljbang-string-replace (s match rep)
  (replace-regexp-in-string (regexp-quote match) rep s))

(defconst cljbang--ns-fns
  '(("clojure.string/join" . cljbang-string-join)
    ("clojure.string/split" . cljbang-string-split)
    ("clojure.string/replace" . cljbang-string-replace)
    ("clojure.string/upper-case" . upcase)
    ("clojure.string/lower-case" . downcase)
    ("clojure.string/capitalize" . capitalize)
    ("clojure.string/trim" . string-trim)
    ("clojure.string/blank?" . string-blank-p)))

(provide 'cljbang-string)
;;; cljbang-string.el ends here
