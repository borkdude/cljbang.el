;; uses map literals
(def scores {:alice 3 :bob 5})

(defn winner [m]
  (if (> (get m :alice) (get m :bob)) :alice :bob))

(println "winner:" (winner scores))
