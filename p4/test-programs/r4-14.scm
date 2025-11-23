(program
 ;; Multiplication
 (define (mul x y)
   (if (<= y 0)
       0
       (+ x (mul x (- y 1)))))

 ;; Check evenness by subtracting 2 repeatedly
 (define (is_even n)
   (let ([r n])
     (let ([_ (while (< 1 r)
                       (set! r (- r 2)))])
       (eq? r 0))))

 ;; Integer division by 2 via repeated subtraction
 (define (half n)
   (let ([r n])
     (let ([k 0])
       (let ([_ (while (< 1 r)
                         (begin
                           (set! r (- r 2))
                           (set! k (+ k 1))))])
         k))))

 ;; Number of Collatz steps to reach 1
 (define (collatz_steps n)
   (let ([steps 0])
     (let ([x n])
       (let ([_ (while (not (eq? x 1))
                         (begin
                           (if (is_even x)
                               (set! x (half x))
                               (set! x (+ (mul 3 x) 1)))
                           (set! steps (+ steps 1))))])
         steps))))

 ;; Sum of collatz_steps(i) for i=1..n
 (define (sum_collatz n)
   (let ([acc 0])
     (let ([i 1])
       (let ([_ (while (<= i n)
                         (begin
                           (set! acc (+ acc (collatz_steps i)))
                           (set! i (+ i 1))))])
         acc))))

 ;; main: read n, compute Σ_{i=1..n} CollatzSteps(i)
 (sum_collatz (read)))
