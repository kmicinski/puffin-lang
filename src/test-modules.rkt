#lang racket

;; Puffin -- test-modules.rkt: the module system's compile-time
;; failure modes (docs/MODULES.md §5.4). The success paths live in
;; the golden corpus (test-programs/modules-*); these are the errors
;; the golden runner can't express. Run: racket src/test-modules.rkt

(require rackunit "modules.rkt")

(define dir (build-path (find-system-path 'temp-dir) "puffin-module-errs"))
(delete-directory/files dir #:must-exist? #f)
(make-directory* dir)

(define (write-mod name . lines)
  (with-output-to-file (build-path dir name) #:exists 'replace
    (λ () (for-each displayln lines)))
  (build-path dir name))

(define-syntax-rule (check-module-error rx entry)
  (check-exn (λ (e) (and (exn:fail? e) (regexp-match? rx (exn-message e))))
             (λ () (resolve-modules entry))))

;; a well-formed dependency used throughout
(void (write-mod "lib.puf"
           "(provide f g)"
           "(define (f x) x)"
           "(define (g x y) (cons x y))"
           "(define hidden 1)"))
(void (write-mod "sig.pufs"
                 "(signature S (val zero) (fun f 1))"))

;; missing provide name
(check-module-error #rx"provides missing, which it does not define"
  (write-mod "p1.puf" "(provide missing)" "(define (f x) x)"))

;; qualified access to a non-provided name
(check-module-error #rx"hidden is not provided"
  (write-mod "p2.puf" "(require \"lib.puf\" #:as L)" "(println (L.hidden 1))"))

;; #:only of a non-provided name
(check-module-error #rx"#:only name hidden is not provided"
  (write-mod "p3.puf" "(require \"lib.puf\" #:only (hidden))" "(println 1)"))

;; require cycle
(void (write-mod "cyc-a.puf" "(require \"cyc-b.puf\")" "(define (a) 1)"))
(void (write-mod "cyc-b.puf" "(require \"cyc-a.puf\")" "(define (b) 2)"))
(check-module-error #rx"require cycle" (build-path dir "cyc-a.puf"))

;; signature: missing name
(check-module-error #rx"signature requires val zero, not defined"
  (write-mod "s1.puf" "(provide #:sig \"sig.pufs\")" "(define (f x) x)"))

;; signature: arity mismatch
(check-module-error #rx"signature fun f expects arity 1, definition has arity 2"
  (write-mod "s2.puf" "(provide #:sig \"sig.pufs\")" "(define zero 0)" "(define (f x y) x)"))

;; signature narrowing: names outside the sig are private
(void (write-mod "s3.puf" "(provide #:sig \"sig.pufs\")" "(define zero 0)"
                 "(define (f x) x)" "(define (extra x) x)"))
(check-module-error #rx"extra is not provided"
  (write-mod "s3-client.puf" "(require \"s3.puf\" #:as S)" "(println (S.extra 1))"))

;; import collision: two modules provide the same name
(void (write-mod "lib2.puf" "(provide f)" "(define (f x) (cons x x))"))
(check-module-error #rx"imported from two different modules"
  (write-mod "p4.puf" "(require \"lib.puf\")" "(require \"lib2.puf\")" "(println (f 1))"))

;; import collides with a local top-level definition
(check-module-error #rx"collides with a local top-level definition"
  (write-mod "p5.puf" "(require \"lib.puf\")" "(define (f x) 0)" "(println (f 1))"))

;; importing a reserved word unqualified
(void (write-mod "kw.puf" "(provide match)" "(define (match a b) a)"))
(check-module-error #rx"cannot import match unqualified"
  (write-mod "p6.puf" "(require \"kw.puf\")" "(println 1)"))

;; missing module file
(check-module-error #rx"required module not found"
  (write-mod "p7.puf" "(require \"no-such.puf\")" "(println 1)"))

;; narrowing sanity: the sig-ascribed module still works for sig names
(check-not-exn
 (λ () (resolve-modules
        (write-mod "ok.puf" "(require \"s3.puf\")" "(println (f zero))"))))

(displayln "module error tests: all passed")
