(ns cyc.b (:require [cyc.a :as a]))

(defn from-b [] "b")

(defn calls-a [] (a/from-a))
