;; Huet zippers for binary trees: navigate, edit in place, rebuild
;; loc = (subtree context); context = top | (left v right-tree ctx) | ...
;; as grammars (docs/GRAMMARS.md): the trees, contexts and locations
;; are plain s-expressions, and every move below is checked to build a
;; well-formed Loc
(define-grammar Tree leaf (node Int Tree Tree))
(define-grammar Ctx top (in-left Int Tree Ctx) (in-right Int Tree Ctx))
(define-grammar Loc (Tree Ctx))
(define (go-left [loc : Loc]) : Loc
  (match loc
    [`((node ,v ,l ,r) ,ctx) `(,l (in-left ,v ,r ,ctx))]))
(define (go-right [loc : Loc]) : Loc
  (match loc
    [`((node ,v ,l ,r) ,ctx) `(,r (in-right ,v ,l ,ctx))]))
(define (go-up [loc : Loc]) : Loc
  (match loc
    [`(,t (in-left ,v ,r ,ctx)) `((node ,v ,t ,r) ,ctx)]
    [`(,t (in-right ,v ,l ,ctx)) `((node ,v ,l ,t) ,ctx)]))
(define (replace [loc : Loc] [t : Tree]) : Loc (match loc [`(,_ ,ctx) `(,t ,ctx)]))
(define (to-top [loc : Loc]) : Tree
  (match loc
    [`(,t top) t]
    [_ (to-top (go-up loc))]))
(define t '(node 1 (node 2 (node 4 leaf leaf) (node 5 leaf leaf))
                   (node 3 leaf (node 7 leaf leaf))))
;; edit node 5 -> 55 by navigating left, right
(define loc1 (go-right (go-left `(,t top))))
(println (car loc1))                                ;; (node 5 leaf leaf)
(define t2 (to-top (replace loc1 '(node 55 leaf leaf))))
(println t2)
(println t)                                          ;; original untouched
;; graft a subtree at 7's left
(define loc2 (go-left (go-right (go-right `(,t top)))))
(println (to-top (replace loc2 '(node 99 leaf leaf))))
(car (go-left `(,t2 top)))
