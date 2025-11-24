(program
 ;; Empty list
 (define (is_nil x) (eq? x (void)))

 ;; cons as vector
 (define (cons h t)
   (let ([c (make-vector 2)])
     (let ([_ (vector-set! c 0 h)])
       (let ([_ (vector-set! c 1 t)])
         c))))

 (define (head c) (vector-ref c 0))
 (define (tail c) (vector-ref c 1))

 ;; Absolute value
 (define (abs x)
   (if (< x 0)
       (- 0 x)
       x))

 ;; Point as 2-element vector [0]=x, [1]=y
 (define (mk_point x y)
   (let ([p (make-vector 2)])
     (let ([_ (vector-set! p 0 x)])
       (let ([_ (vector-set! p 1 y)])
         p))))

 (define (point_x p) (vector-ref p 0))
 (define (point_y p) (vector-ref p 1))

 ;; Manhattan distance of point from origin
 (define (manhattan p)
   (let ([x (point_x p)])
     (let ([y (point_y p)])
       (+ (abs x) (abs y)))))

 ;; Read n points (x,y) into a list
 (define (read_points n)
   (let ([xs (void)])
     (let ([i 0])
       (let ([_ (while (< i n)
                       (begin
                         (let* ([x (read)]
                                [y (read)]
                                [p (mk_point x y)])
                           (set! xs (cons p xs)))
                         (set! i (+ i 1))))])
         xs))))

 ;; Max Manhattan distance over a list of points
 (define (max_manhattan xs)
   (if (is_nil xs)
       0
       (let ([best (manhattan (head xs))])
         (let ([rest (tail xs)])
           (let ([_ (while (not (is_nil rest))
                             (begin
                               (let ([v (manhattan (head rest))])
                                 (if (< best v)
                                     (set! best v)
                                     (void)))
                               (set! rest (tail rest))))])
             best)))))

 ;; main:
 ;;  read n
 ;;  read n points
 ;;  return max manhattan distance
 (let* ([n (read)]
        [pts (read_points n)])
   (max_manhattan pts)))
