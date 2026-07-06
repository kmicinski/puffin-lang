;; Church encodings: booleans, pairs, numerals -- with pred via pairs
(define (to-int n) ((n add1) 0))
(define czero (lambda (f) (lambda (x) x)))
(define (csucc n) (lambda (f) (lambda (x) (f ((n f) x)))))
(define (cplus m n) (lambda (f) (lambda (x) ((m f) ((n f) x)))))
(define (cmul m n) (lambda (f) (n (m f))))
(define ctrue (lambda (a) (lambda (b) a)))
(define cfalse (lambda (a) (lambda (b) b)))
(define (cif c t e) (((c (lambda (_) t)) (lambda (_) e)) 0)) ;; thunked via dummy
(define (cpair a b) (lambda (sel) ((sel a) b)))
(define (cfst p) (p ctrue))
(define (csnd p) (p cfalse))
(define (czero? n) ((n (lambda (_) cfalse)) ctrue))
;; pred: fold building (i-1, i) pairs
(define (cpred n)
  (cfst ((n (lambda (p) (cpair (csnd p) (csucc (csnd p)))))
         (cpair czero czero))))
(define c3 (csucc (csucc (csucc czero))))
(define c5 (cplus c3 (csucc (csucc czero))))
(println (to-int (cplus c3 c5)))          ;; 8
(println (to-int (cmul c3 c5)))           ;; 15
(println (to-int (cpred c5)))             ;; 4
(println (cif (czero? czero) 'zero 'nonzero))
(println (cif (czero? c3) 'zero 'nonzero))
(println (to-int (cfst (cpair c5 c3))))   ;; 5
;; church exponentiation: n^m = (m n)
(define (cexp n m) (m n))
(to-int (cexp c3 c5))                     ;; 243
