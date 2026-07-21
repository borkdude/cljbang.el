;; -*- mode: clojure; cljbang-whole-buffer: t -*-
(ns my-test-file
  (:require [clojure.string :as str]))

(defn my-emacs-version []
  (-> (str/split (el/emacs-version) " ")
      (nth 2)))

(comment
  (my-emacs-version)
  (#{1 2 3} 1)
  (let [x 1]
    (#{x} 1))
  1)

(defn foo [{:keys [x]}]
  [x])

(foo {:x 1})

(count {:a 1 :b 2})

(assoc {:a 1} :b 2)

