(program
 ;; =========================
 ;; List primitives (as in ex3)
 ;; Empty list is (void)
 ;; =========================
 (define (is_nil x) (eq? x (void)))

 ;; cons cell as 2-element vector: [0] = head, [1] = tail
 (define (cons h t)
   (let ([c (make-vector 2)])
     (let ([_ (vector-set! c 0 h)])
       (let ([_ (vector-set! c 1 t)])
         c))))

 (define (head c) (vector-ref c 0))
 (define (tail c) (vector-ref c 1))

 ;; =========================
 ;; Cell representation
 ;; cell = (row col val) as nested cons
 ;; =========================
 (define (make_cell r c v)
   (cons r (cons c (cons v (void)))))

 (define (cell_row cell)
   (head cell))

 (define (cell_col cell)
   (head (tail cell)))

 (define (cell_val cell)
   (head (tail (tail cell))))

 ;; =========================
 ;; Block indexing (0,1,2) for rows/cols
 ;; =========================
 (define (block_index3 x)
   (if (< x 3)
       0
       (if (< x 6)
           1
           2)))

 (define (same_block? r1 c1 r2 c2)
   (if (eq? (block_index3 r1) (block_index3 r2))
       (eq? (block_index3 c1) (block_index3 c2))
       #f))

 ;; =========================
 ;; Lookup current value at (row, col) in board
 ;; board is a list of cells
 ;; Return 0 if not assigned
 ;; =========================
 (define (lookup board row col)
   (if (is_nil board)
       0
       (let ([cell (head board)])
         (let ([r (cell_row cell)])
           (let ([c (cell_col cell)])
             (if (and (eq? r row) (eq? c col))
                 (cell_val cell)
                 (lookup (tail board) row col)))))))

 ;; =========================
 ;; Conflict check:
 ;; #t if some cell in board has:
 ;;   - same value, and
 ;;   - same row OR same col OR same 3x3 block
 ;; =========================
 (define (conflicts? board row col val)
   (if (is_nil board)
       #f
       (let ([cell (head board)])
         (let ([r (cell_row cell)])
           (let ([c (cell_col cell)])
             (let ([v (cell_val cell)])
               (if (and (eq? v val)
                        (or (eq? r row)
                            (or (eq? c col)
                                (same_block? r c row col))))
                   #t
                   (conflicts? (tail board) row col val))))))))

 ;; =========================
 ;; Recursive backtracking solver over (row, col)
 ;; board: list of assignments
 ;; rows, cols = 0..8
 ;; =========================
 (define (solve_cell row col board)
   (if (eq? row 9)
       ;; All rows done: solved
       board
       (if (eq? col 9)
           ;; End of row: go to next row
           (solve_cell (+ row 1) 0 board)
           ;; Otherwise, try this cell
           (let ([existing (lookup board row col)])
             (if (eq? existing 0)
                 ;; Empty cell: try values 1..9
                 (let ([candidate 1])
                   (let ([solution (void)])
                     (begin
                       (while (and (< candidate 10)
                                   (eq? solution (void)))
                              (begin
				(if (conflicts? board row col candidate)
                                    ;; conflict, skip
                                    (set! solution solution)
                                    ;; no conflict, extend board and recurse
                                    (let ([s (solve_cell row
                                                         (+ col 1)
                                                         (cons (make_cell row col candidate)
                                                               board))])
                                      (if (eq? s (void))
                                          (set! solution solution)
                                          (set! solution s))))
				(set! candidate (+ candidate 1))))
                       solution)))
                 ;; Pre-filled cell: just move on
                 (solve_cell row (+ col 1) board))))))

 ;; =========================
 ;; Read initial board from input:
 ;; 81 integers, row-major, 0 = empty, 1..9 = given
 ;; Returns list of cells
 ;; =========================
 (define (read_board)
   (let ([board (void)])
     (let ([i 0])
       (begin
         (while (< i 9)
		(begin
                  (let ([j 0])
                    (while (< j 9)
			   (begin
			     (let ([v (read)])
                               (if (eq? v 0)
				   (set! board board)
				   (set! board (cons (make_cell i j v) board))))
			     (set! j (+ j 1)))))
                  (set! i (+ i 1))))
         board))))

 ;; =========================
 ;; Entry: read board, solve from (0,0), return solution
 ;; Solution is a list of (row col val) cells
 ;; =========================
 (let* ([board (read_board)]
        [solution (solve_cell 0 0 board)])
   (lookup solution 8 8)))
