(program
 ;; Empty list is represented as (void).
 (define (is_nil x) (eq? x (void)))

 ;; cons cell as a 2-element vector:
 ;; [0] = head, [1] = tail
 (define (cons h t)
   (let ([c (make-vector 2)])
     (let ([_ (vector-set! c 0 h)])
       (let ([_ (vector-set! c 1 t)])
         c))))

 (define (head c) (vector-ref c 0))
 (define (tail c) (vector-ref c 1))

 ;; append xs ++ ys
 (define (append xs ys)
   (if (is_nil xs)
       ys
       (cons (head xs)
             (append (tail xs) ys))))

 ;; length of list
 (define (length l)
   (if (is_nil l)
       0
       (+ 1 (length (tail l)))))

 ;; sum elements of list
 (define (sum_list xs)
   (if (is_nil xs)
       0
       (+ (head xs) (sum_list (tail xs)))))

 ;; absolute value
 (define (abs x)
   (if (< x 0)
       (- 0 x)
       x))

 ;; double a number (used by map_double)
 (define (double x)
   (+ x x))

 ;; map a *top-level* function `double` over a list
 (define (map_double xs)
   (if (is_nil xs)
       (void)
       (cons (double (head xs))
             (map_double (tail xs)))))

 ;; map a *top-level* function `abs` over a list
 (define (map_abs xs)
   (if (is_nil xs)
       (void)
       (cons (abs (head xs))
             (map_abs (tail xs)))))

 ;; filter elements >= 0
 (define (filter_nonneg xs)
   (if (is_nil xs)
       (void)
       (let ([h (head xs)])
         (let ([t (tail xs)])
           (if (< h 0)
               (filter_nonneg t)
               (cons h (filter_nonneg t)))))))

 ;; Build list from n reads (front-accumulated)
 (define (read_list n)
   (let ([xs (void)])
     (let ([i 0])
       (let ([_ (while (< i n)
                       (begin
                         (let ([v (read)])
                           (set! xs (cons v xs)))
                         (set! i (+ i 1))))])
         xs))))

 ;; Entry expression:
 ;;  - read n
 ;;  - read n numbers into a list
 ;;  - map double and abs over the list using the top-level functions
 ;;  - keep only non-negative absolute values
 ;;  - return sum of:
 ;;      sum(map_double xs) ++ sum(filter_nonneg (map_abs xs))
 (let* ([n (+ 2 (read))]
        [xs (read_list n)]
        [doubles (map_double xs)]
        [abss (map_abs xs)]
        [nonneg (filter_nonneg abss)]
        [sum_doubles (sum_list doubles)]
        [sum_nonneg (sum_list nonneg)])
   (+ sum_doubles sum_nonneg)))
