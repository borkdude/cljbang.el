;; -*- mode: clojure; cljbang-whole-buffer: t -*-

;; Syntax that needs source text, so it works in a .clj file but not
;; inside clj!: map literals, set literals and #().

(ns literals
  (:require [clojure.string :as str]))

(def scores {:alice 3 :bob 5})

(defn winner [{:keys [alice bob]}]
  (if (> alice bob) :alice :bob))

(def finalists #{:alice :bob})

(defn- shout [s]
  (str/upper-case s))

(println "winner:" (shout (name (winner scores))))
(println "finalists:" (count finalists))
(println "doubled:" (map #(* 2 %) [1 2 3]))
