(ns foo)

(defn foobar [x] (* x 2))

(defn baz [x] (+ (foobar x) 1))

(println "loaded ns foo, (baz 20) =" (baz 20))
