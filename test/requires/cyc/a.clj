(ns cyc.a (:require [cyc.b :as b]))

(defn from-a [] "a")

;; referenced but not called, so the requires stay circular on purpose
(defn calls-b [] (b/from-b))
