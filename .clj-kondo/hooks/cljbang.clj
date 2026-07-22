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
    ;; kept whole: lint-as do lints the body, and clj! counts as used
    (clj-bang-call? node)
    [node]
    :else
    (mapcat cljbang-parts (:children node))))

(defn clj-bang
  "Lint (clj! ...) as its body, with no do to call redundant."
  [{:keys [node]}]
  (let [body (rest (:children node))]
    {:node (if (= 1 (count body))
             (first body)
             (api/list-node (list* (api/token-node 'do) body)))}))

(defn el-bang
  "Lint (el! ...) as its clj! parts."
  [{:keys [node]}]
  (let [parts (cljbang-parts node)]
    {:node (if (= 1 (count parts))
             (first parts)
             (api/list-node (list* (api/token-node 'do) parts)))}))
