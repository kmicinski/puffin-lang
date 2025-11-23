(program
 ;; Multiplication not strictly needed here, but harmless to have.
 (define (mul x y)
   (if (<= y 0)
       0
       (+ x (mul x (- y 1)))))

 ;; Check if d divides n using repeated subtraction
 (define (divides? d n)
   (let ([r n])
     (let ([_ (while (< 0 r)
                       (set! r (- r d)))])
       (eq? r 0))))

 ;; Test primality by checking divisors from 2..n-1
 (define (is_prime n)
   (if (< n 2)
       #f
       (let ([d 2])
         (let ([prime #t])
           (let ([_ (while (and prime (< d n))
                             (begin
                               (if (divides? d n)
                                   (set! prime #f)
                                   (set! d (+ d 1)))))])
             prime)))))

 ;; Count primes from 0..n
 (define (count_primes n)
   (let ([cnt 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
                         (begin
                           (if (is_prime i)
                               (set! cnt (+ cnt 1))
                               (void))
                           (set! i (+ i 1))))])
         cnt))))

 ;; main: read n, output #primes ≤ n
 (count_primes (read)))
