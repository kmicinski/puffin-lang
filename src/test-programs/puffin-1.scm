;; stress: globals, closures, match, hashes, sets, symbols, strings, loops
(define version 'v1)
(define (make-counter)
  (let ([n 0])
    (lambda () (begin (set! n (+ n 1)) n))))
(define c (make-counter))
(c) (c)
(println (c))                          ;; 3

(define h (make-hash))
(hash-set! h 'a 1)
(hash-set! h 'b 2)
(println (hash-ref h 'b))              ;; 2
(println (hash-count h))               ;; 2
(hash-remove! h 'a)
(println (hash-has-key? h 'a))         ;; #f

(define s (make-set))
(let loop ([i 0])
  (when (< i 100) (set-add! s (remainder i 7)) (loop (+ i 1))))
(println (set-count s))                ;; 7

(define (sum-list xs)
  (match xs
    ['() 0]
    [(cons hd tl) (+ hd (sum-list tl))]))
(println (sum-list (list 1 2 3 4 5)))  ;; 15

(define (eval-expr e)
  (match e
    [`(add ,a ,b) (+ (eval-expr a) (eval-expr b))]
    [`(mul ,a ,b) (* (eval-expr a) (eval-expr b))]
    [(? fixnum? n) n]))
(println (eval-expr '(add (mul 3 4) (add 1 2))))  ;; 15

(println (string-append "hello, " "world"))
(println (vector 1 (list 2 3) 'sym #t))
(println version)
(let fib ([n 20])
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
