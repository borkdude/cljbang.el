(ns hooks.cljbang
  (:require [clj-kondo.hooks-api :as api]))

(defn- unquoted
  "The ~forms in NODE, at any depth.  Everything else is elisp."
  [node]
  (if (contains? #{:unquote :unquote-splicing} (api/tag node))
    (:children node)
    (mapcat unquoted (:children node))))

(defn el-bang
  "Lint (el! ...) as (do <the ~unquoted cljbang forms>)."
  [{:keys [node]}]
  {:node (api/list-node
          (list* (api/token-node 'do) (unquoted node)))})
