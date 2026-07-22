(ns hooks.cljbang
  (:require [clj-kondo.hooks-api :as api]))

(defn- clj-bang-call? [node]
  (and (= :list (api/tag node))
       (let [head (first (:children node))]
         (and head
              (= :token (api/tag head))
              (= 'clj! (api/sexpr head))))))

(defn- cljbang-parts
  "The (clj! ...) bodies in NODE, at any depth.  Everything else is
elisp, except a stray ~, which el! refuses."
  [node]
  (cond
    (contains? #{:unquote :unquote-splicing} (api/tag node))
    (do (api/reg-finding!
         (assoc (meta node)
                :message "inside el! the door back is (clj! ...), not ~"
                :type :cljbang/el-bang))
        nil)
    (clj-bang-call? node)
    (rest (:children node))
    :else
    (mapcat cljbang-parts (:children node))))

(defn el-bang
  "Lint (el! ...) as (do <its clj! bodies>)."
  [{:keys [node]}]
  {:node (api/list-node
          (list* (api/token-node 'do) (cljbang-parts node)))})
