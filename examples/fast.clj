;; -*- mode: clojure; cljbang-whole-buffer: t -*-

(ns fast
  (:require [clojure.string :as str]))

;; stays in the elisp-readable subset: loaded by the C reader
(defn fib [n]
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(def fibs (map fib [1 2 3 4 5 6 7 8 9 10]))

(println "fibs:" fibs)
(println "joined:" (str/join ", " fibs))
;; trailing comment on purpose
(str [1 2 3])
