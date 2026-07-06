;; n-queens by list recursion: count solutions and show one board
(define (safe? col placed dist)
  (match placed
    ['() #t]
    [(cons p rest)
     (and (not (eq? p col))
          (not (eq? p (+ col dist)))
          (not (eq? p (- col dist)))
          (safe? col rest (+ dist 1)))]))
(define (solve n)
  (define (place row placed)
    (if (eq? row n)
        (list placed)
        (append-map
         (lambda (col) (if (safe? col placed 1) (place (+ row 1) (cons col placed)) '()))
         (range 0 n))))
  (place 0 '()))
(println (map (lambda (n) (length (solve n))) (range 1 9)))  ;; 1 0 0 2 10 4 40 92
(println (car (solve 6)))
;; render the first 5-queens solution as a board
(define (row-str col n)
  (foldl (lambda (i acc) (string-append acc (if (eq? i col) "Q" ".")))
         "" (range 0 n)))
(define (show placed n)
  (foldl (lambda (c acc) (begin (println (row-str c n)) acc)) (void) (reverse placed)))
(show (car (solve 5)) 5)
(length (solve 7))
