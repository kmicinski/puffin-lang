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
 (define (length l)
   (if (is_nil l)
       0
       (+ 1 (length (tail l)))))
 ;; filter elements < p
 (define (filterlt p xs)
   (if (is_nil xs)
       (void)
       (let ([h (head xs)])
         (let ([t (tail xs)])
           (if (< h p)
               (cons h (filterlt p t))
               (filterlt p t))))))
 ;; filter elements >= p
 (define (filterge p xs)
   (if (is_nil xs)
       (void)
       (let ([h (head xs)])
         (let ([t (tail xs)])
           (if (< h p)
               (filterge p t)
               (cons h (filterge p t)))))))
 ;; quicksort on our list representation
 (define (qsort xs)
   (if (is_nil xs)
       (void)
       (let ([pivot (head xs)])
         (let ([rest (tail xs)])
           (let ([small (filterlt pivot rest)])
             (let ([big (filterge pivot rest)])
               (append (qsort small)
                       (cons pivot (qsort big)))))))))
 ;; sum elements of list
 (define (get_nth xs n)
   (if (eq? n 0)
       (head xs)
       (get_nth (tail xs) (- n 1))))
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
 ;;  - quicksort the list
 ;;  - return sum of sorted list
 (let* ([n (read)]
        [xs (read_list n)]
        [sorted (qsort xs)]
        [j (read)]
        [k (if (< j (length sorted)) j (- (length sorted) 1))])
   (get_nth sorted k)))
