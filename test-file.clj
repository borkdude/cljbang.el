;; -*- mode: clojure; clj2el-whole-buffer: t -*-
(ns my-test-file
  (:require [clojure.string :as str]))

(defn my-emacs-version []
  (subs (emacs-version) 0 15))

(comment
  (my-emacs-version)
  )


