(program
 ;; Empty list as (void)
 (define (is_nil x) (eq? x (void)))
 ;; cons cell as 2-element vector: [0]=head, [1]=tail
 (define (cons h t)
   (let ([c (make-vector 2)])
     (let ([_ (vector-set! c 0 h)])
       (let ([_ (vector-set! c 1 t)])
         c))))
 (define (head c) (vector-ref c 0))
 (define (tail c) (vector-ref c 1))
 ;; Multiplication via repeated addition
 (define (mul x y)
   (if (<= y 0)
       0
       (+ x (mul x (- y 1)))))
 ;; Read n integers into a list (front-accumulated)
 (define (read_list n)
   (let ([xs (void)])
     (let ([i 0])
       (let ([_ (while (< i n)
                       (begin
                         (let ([v (read)])
                           (set! xs (cons v xs)))
                         (set! i (+ i 1))))])
         xs))))
 ;; Evaluate polynomial with coefficients in a list:
 ;;   coeffs = [a0, a1, ..., ak] (in some order)
 ;;   using recursive Horner-like evaluation: a0 + x * eval(rest, x)
 (define (eval_poly coeffs x)
   (if (is_nil coeffs)
       0
       (let ([rest (tail coeffs)])
         (let ([rec (eval_poly rest x)])
           (+ (head coeffs) (mul x rec))))))
 ;; main:
 ;;  read degree d
 ;;  read d+1 coefficients
 ;;  read x
 ;;  evaluate polynomial
 (let* ([deg (read)]
        [n (+ deg 1)]
        [coeffs (read_list n)]
        [x (read)])
   (eval_poly coeffs x)))
