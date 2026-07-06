;; Huet zippers for binary trees: navigate, edit in place, rebuild
;; loc = (subtree context); context = top | (left v right-tree ctx) | ...
(define (go-left loc)
  (match loc
    [`((node ,v ,l ,r) ,ctx) `(,l (in-left ,v ,r ,ctx))]))
(define (go-right loc)
  (match loc
    [`((node ,v ,l ,r) ,ctx) `(,r (in-right ,v ,l ,ctx))]))
(define (go-up loc)
  (match loc
    [`(,t (in-left ,v ,r ,ctx)) `((node ,v ,t ,r) ,ctx)]
    [`(,t (in-right ,v ,l ,ctx)) `((node ,v ,l ,t) ,ctx)]))
(define (replace loc t) (match loc [`(,_ ,ctx) `(,t ,ctx)]))
(define (to-top loc)
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
