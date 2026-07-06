;; puffin-10: the bootstrap seed -- two passes of the Puffin compiler
;; written IN Puffin, in exactly the house style: quasiquote-match
;; with ellipsis over program shapes, quasiquote construction on the
;; way out, internal defines for the walkers.
;;
;; `shrink` matches src/compile.rkt's shrink on the core forms;
;; `uniqueify` uses a deterministic fresh-name supply (a counter in a
;; box) so this program's output is identical across the reference
;; interpreter, both native backends, and the web interpreter --
;; gensym itself is exercised at the end, where only freshness (not
;; spelling) is asserted.

(define (shrink e)
  (match e
    [(? fixnum? n) n]
    [(? symbol? x) x]
    [#t #t]
    [#f #f]
    [`(read) '(read)]
    [`(- ,e0 ,e1) `(+ ,(shrink e0) (- ,(shrink e1)))]
    [`(- ,e0) `(- ,(shrink e0))]
    [`(+ ,e0 ,e1) `(+ ,(shrink e0) ,(shrink e1))]
    [`(and ,e0 ,e1) `(if ,(shrink e0) ,(shrink e1) #f)]
    [`(or ,e0 ,e1) (let ([t 'or-tmp]) `(let ([,t ,(shrink e0)]) (if ,t ,t ,(shrink e1))))]
    [`(not ,e0) `(eq? ,(shrink e0) #f)]
    [`(<= ,e0 ,e1) (shrink `(not (< ,e1 ,e0)))]
    [`(> ,e0 ,e1) (shrink `(< ,e1 ,e0))]
    [`(>= ,e0 ,e1) (shrink `(not (< ,e0 ,e1)))]
    [`(< ,e0 ,e1) `(< ,(shrink e0) ,(shrink e1))]
    [`(eq? ,e0 ,e1) `(eq? ,(shrink e0) ,(shrink e1))]
    [`(if ,g ,t ,f) `(if ,(shrink g) ,(shrink t) ,(shrink f))]
    [`(let ([,x ,e0]) ,body) `(let ([,x ,(shrink e0)]) ,(shrink body))]
    [`(,f ,args ...) `(,(shrink f) ,@(map shrink args))]))

(define (shrink-program p)
  (match p
    [`(program (define (,fs ,formalss ...) ,bodies) ... ,main)
     `(program
       ,@(map2 (lambda (f rest)
                 (match rest
                   [(cons formals body) `(define (,f ,@formals) ,(shrink body))]))
               fs
               (map2 cons formalss bodies))
       (define (main) ,(shrink main)))]))

;; deterministic uniqueify: fresh names from a counter, renamed only
;; on collision within a definition (the class discipline)
(define (uniqueify-defn defn)
  (define counter (vector 0))
  (define used (make-set))
  (define (fresh! x)
    (if (set-member? used x)
        (begin
          (vector-set! counter 0 (+ 1 (vector-ref counter 0)))
          (string->symbol
           (string-append (symbol->string x)
                          (string-append "." (number->string (vector-ref counter 0))))))
        (begin (set-add! used x) x)))
  (define (rename e env)
    (match e
      [(? fixnum? n) n]
      [#t #t]
      [#f #f]
      [`(read) e]
      [(? symbol? x) (hash-ref/default env x x)]
      [`(let ([,x ,e0]) ,body)
       (let ([x+ (fresh! x)])
         `(let ([,x+ ,(rename e0 env)]) ,(rename body (hash-set env x x+))))]
      [`(if ,g ,t ,f) `(if ,(rename g env) ,(rename t env) ,(rename f env))]
      [`(,f ,args ...) `(,(rename f env) ,@(map (lambda (a) (rename a env)) args))]))
  (match defn
    [`(define (,f ,formals ...) ,body)
     (let ([formals+ (map fresh! formals)])
       `(define (,f ,@formals+)
          ,(rename body
                   (foldl (lambda (pr acc) (hash-set acc (car pr) (cdr pr)))
                          (hash)
                          (map2 cons formals formals+)))))]))

(define (uniqueify-program p)
  (match p
    [`(program ,defns ...) `(program ,@(map uniqueify-defn defns))]))

;; ---- run both passes over an embedded program -----------------------

(define demo
  '(program
    (define (choose a b)
      (if (>= a b) a b))
    (define (clamp x)
      (let ([y (- x 1)])
        (let ([y (and (> y 0) y)])   ;; shadowing: uniqueify must rename
          (if y y 0))))
    (choose (clamp (read)) (- 10 (read)))))

(define shrunk (shrink-program demo))
(println shrunk)
(define unique (uniqueify-program shrunk))
(println unique)

;; gensym: only freshness is asserted (spellings differ per host)
(define gs (map (lambda (_) (gensym 'g)) (range 0 4)))
(define (all-distinct? xs)
  (match xs
    ['() #t]
    [(cons hd tl) (and (not (member hd tl)) (all-distinct? tl))]))
(println (list (andmap symbol? gs) (all-distinct? gs)))
'bootstrap-seed-ok
