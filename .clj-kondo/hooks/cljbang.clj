(ns hooks.cljbang
  (:require [clj-kondo.hooks-api :as api]))

(defn- clj-bang-call? [node]
  (and (= :list (api/tag node))
       (let [head (first (:children node))]
         (and head
              (= :token (api/tag head))
              (= 'clj! (api/sexpr head))))))

(defn- unquoted
  "The cljbang inside NODE: ~forms and (clj! ...) bodies, at any depth.
Everything else is elisp."
  [node]
  (cond
    (contains? #{:unquote :unquote-splicing} (api/tag node))
    (:children node)
    (clj-bang-call? node)
    (rest (:children node))
    :else
    (mapcat unquoted (:children node))))

(defn el-bang
  "Lint (el! ...) as (do <its cljbang parts>)."
  [{:keys [node]}]
  {:node (api/list-node
          (list* (api/token-node 'do) (unquoted node)))})
