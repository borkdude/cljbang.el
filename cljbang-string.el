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
  (apply #'vector (split-string s (cljbang--regex-string re))))

(defun cljbang-string-replace (s match rep)
  "Replace MATCH in S with REP.  A string MATCH is literal, a regex is not."
  (if (cljbang--regex-p match)
      (replace-regexp-in-string (aref match 1) rep s)
    (replace-regexp-in-string (regexp-quote match) rep s t t)))

(defun cljbang-string-replace-first (s match rep)
  "Like `cljbang-string-replace', but only the first match."
  (let ((p (if (cljbang--regex-p match) (aref match 1) (regexp-quote match))))
    (if (string-match p s)
        (concat (substring s 0 (match-beginning 0)) rep (substring s (match-end 0)))
      s)))

(defun cljbang-string-includes? (s substr)
  (and (string-search substr s) t))

(defun cljbang-string-starts-with? (s substr)
  ;; elisp takes the prefix first, Clojure takes the string first
  (string-prefix-p substr s))

(defun cljbang-string-ends-with? (s substr)
  (string-suffix-p substr s))

(defun cljbang-string-index-of (s value &optional from)
  "Index of VALUE in S at or after FROM, or nil.  Clojure returns nil, not -1."
  (string-search value s from))

(defun cljbang-string-last-index-of (s value)
  "Index of the last VALUE in S, or nil."
  (let ((found nil) (i 0))
    (while (setq i (string-search value s i))
      (setq found i
            i (1+ i)))
    found))

(defun cljbang-string-split-lines (s)
  (apply #'vector (split-string s "\n")))

(defun cljbang-string-trim-newline (s)
  "S without trailing newline and return characters."
  (if (string-match "[\n\r]+\\'" s)
      (substring s 0 (match-beginning 0))
    s))

(defconst cljbang--ns-fns
  '(("clojure.edn/read-string" . cljbang-edn-read-string)
    ("clojure.string/join" . cljbang-string-join)
    ("clojure.string/split" . cljbang-string-split)
    ("clojure.string/replace" . cljbang-string-replace)
    ("clojure.string/replace-first" . cljbang-string-replace-first)
    ("clojure.string/upper-case" . upcase)
    ("clojure.string/lower-case" . downcase)
    ("clojure.string/capitalize" . capitalize)
    ("clojure.string/trim" . string-trim)
    ("clojure.string/blank?" . string-blank-p)
    ("clojure.string/includes?" . cljbang-string-includes?)
    ("clojure.string/starts-with?" . cljbang-string-starts-with?)
    ("clojure.string/ends-with?" . cljbang-string-ends-with?)
    ("clojure.string/index-of" . cljbang-string-index-of)
    ("clojure.string/last-index-of" . cljbang-string-last-index-of)
    ("clojure.string/split-lines" . cljbang-string-split-lines)
    ("clojure.string/trim-newline" . cljbang-string-trim-newline)
    ("clojure.string/triml" . string-trim-left)
    ("clojure.string/trimr" . string-trim-right)
    ("clojure.string/reverse" . reverse)))

(provide 'cljbang-string)
;;; cljbang-string.el ends here
