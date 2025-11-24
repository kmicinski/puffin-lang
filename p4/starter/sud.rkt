#lang racket

;; -----------------------------
;; Board representation
;; -----------------------------
;; board : (vector 9 of (vector 9 of integer))
;; 0 means empty, 1..9 are digits.

(define (make-empty-board)
  (build-vector 9 (λ (_) (make-vector 9 0))))

(define (board-ref b r c)
  (vector-ref (vector-ref b r) c))

(define (board-set! b r c v)
  (vector-set! (vector-ref b r) c v))

;; Deep copy
(define (clone-board b)
  (build-vector 9
    (λ (r)
      (build-vector 9
        (λ (c)
          (board-ref b r c))))))

;; -----------------------------
;; Validity checks
;; -----------------------------

(define (row-ok? b r v)
  (for/and ([c (in-range 9)])
    (not (= (board-ref b r c) v))))

(define (col-ok? b c v)
  (for/and ([r (in-range 9)])
    (not (= (board-ref b r c) v))))

(define (block-ok? b r c v)
  (define br (* 3 (quotient r 3)))
  (define bc (* 3 (quotient c 3)))
  (for*/and ([dr (in-range 3)]
             [dc (in-range 3)])
    (not (= (board-ref b (+ br dr) (+ bc dc)) v))))

(define (valid-move? b r c v)
  (and (row-ok? b r v)
       (col-ok? b c v)
       (block-ok? b r c v)))

;; -----------------------------
;; Find first empty cell
;; -----------------------------
;; Returns:
;;   - #f if no empty cell
;;   - (vector r c) if an empty cell is found

(define (find-empty b)
  (let loop-rows ([r 0])
    (cond
      [(= r 9) #f]
      [else
       (let loop-cols ([c 0])
         (cond
           [(= c 9) (loop-rows (add1 r))]
           [(zero? (board-ref b r c))
            (vector r c)]
           [else (loop-cols (add1 c))]))])))

;; -----------------------------
;; Backtracking solver
;; -----------------------------
;; Returns a *new* solved board, or #f if unsolvable.

(define (solve-board b)
  (define p (find-empty b))
  (cond
    [(not p)
     ;; no empty cells -> solved
     b]
    [else
     (define r (vector-ref p 0))
     (define c (vector-ref p 1))
     (let try-val ([v 1])
       (cond
         [(> v 9) #f] ; all tried, fail
         [else
          (if (valid-move? b r c v)
              (let ([nb (clone-board b)])
                (board-set! nb r c v)
                (define solved (solve-board nb))
                (if solved
                    solved
                    (try-val (add1 v))))
              (try-val (add1 v)))]))]))

;; -----------------------------
;; Converting from integer list
;; -----------------------------
;; ints: (listof integer), uses *first 81* as Sudoku.
;; Returns a board.

(define (ints->board ints)
  (define b (make-empty-board))
  (for ([idx (in-naturals)]
        [v ints]
        #:break (>= idx 81))
    (define r (quotient idx 9))
    (define c (remainder idx 9))
    (board-set! b r c v))
  b)

(define (solve-sudoku-from-int-list ints)
  (define b (ints->board ints))
  (solve-board b))

;; -----------------------------
;; Pretty-printing
;; -----------------------------

(define (print-board b)
  (for ([r (in-range 9)])
    (for ([c (in-range 9)])
      (display (board-ref b r c))
      (if (= c 8)
          (newline)
          (display " ")))))


;; -----------------------------
;; Main: read giant list of ints
;; -----------------------------
;; Reads *all* integers from stdin into a list,
;; solves Sudoku from the first 81, prints solution.


(module+ main
  (define all-ints '(8 0 0 0 0 0 0 0 0
0 0 3 6 0 0 0 0 0
0 7 0 0 9 0 2 0 0
0 5 0 0 0 7 0 0 0
0 0 0 0 4 5 7 0 0
0 0 0 1 0 0 0 3 0
0 0 1 0 0 0 0 6 8
0 0 8 5 0 0 0 1 0
0 9 0 0 0 0 4 0 0))
  (when (< (length all-ints) 81)
    (error 'main "Need at least 81 integers for Sudoku puzzle"))
  (define solution (solve-sudoku-from-int-list all-ints))
  (if solution
      (print-board solution)
      (begin
        (displayln "No solution found.")
        (void))))
