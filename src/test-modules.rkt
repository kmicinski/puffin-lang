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

;; ---------------------------------------------------------------------
;; types across modules (docs/MODULES.md "Types are module citizens"):
;; provide/require carry TYPE names; diagnostics are demangled. These
;; run the full front ends -- bin/puffin -i and build/puffincc -- and
;; demand BYTE-IDENTICAL messages from both compilers.
;; Needs: build/puffincc (bin/build-puffincc), bin/puffin-vm
;; (make -C src/vm).
;; ---------------------------------------------------------------------

(require racket/runtime-path)
(define-runtime-path here ".")
(define repo (simplify-path (build-path here 'up)))
(define puffin-cli (path->string (build-path repo "bin" "puffin")))
(define puffin-vm  (path->string (build-path repo "bin" "puffin-vm")))
(define puffincc   (path->string (build-path repo "build" "puffincc")))

(define (run! cmd . args)
  (define-values (proc out in err) (apply subprocess #f #f #f cmd args))
  (close-output-port in)
  (define so (port->string out))
  (define se (port->string err))
  (subprocess-wait proc)
  (values (subprocess-status proc) so se))

;; the exporter for the cross-module checks: provides the TYPE
(void (write-mod "shapes.puf"
                 "(provide Shape Point Circle Rect area)"
                 "(define-type Shape (Point) (Circle Int) (Rect Int Int))"
                 "(define (area [s : Shape]) : Int"
                 "  (match s [Point 0] [(Circle r) (* 3 (* r r))] [(Rect w h) (* w h)]))"))
;; ...and one that does NOT provide it
(void (write-mod "shapes-np.puf"
                 "(provide Point Circle Rect area)"
                 "(define-type Shape (Point) (Circle Int) (Rect Int Int))"
                 "(define (area [s : Shape]) : Int"
                 "  (match s [Point 0] [(Circle r) (* 3 (* r r))] [(Rect w h) (* w h)]))"))

;; both compilers on the same entry file -> (exit stdout stderr) each.
;; NOTE the stream split: the reference CLI reports compile errors on
;; STDERR; puffincc reports them via the (error ...) prim, which
;; prints on STDOUT by design (core.c pf_error: golden tests see
;; identical output from binaries and interpreters). The MESSAGE
;; bytes are what must agree.
(define (front-ends entry)
  (define-values (ec1 so1 se1) (run! puffin-cli "-i" (path->string entry)))
  (define-values (ec2 so2 se2)
    ;; -t bytecode: no clang link, so stderr is exactly the front
    ;; end's output (byte-comparable against the reference's)
    (run! puffincc (path->string entry) "-t" "bytecode"
          "-o" (path->string (build-path dir "xm-out.pbc"))))
  (values (list ec1 so1 se1) (list ec2 so2 se2)))

;; an imported type name resolves in every annotation position
(let ([entry (write-mod "xm-ok.puf"
                        "(require \"shapes.puf\")"
                        "(define (describe [s : Shape]) : Sym"
                        "  (match s [Point 'dot] [(Circle _) 'round] [(Rect _ _) 'box]))"
                        "(println (describe (Circle 7)))")])
  (define-values (r p) (front-ends entry))
  (check-equal? (first r) 0)
  (check-equal? (second r) "round\n")
  (check-equal? (first p) 0))

;; importing a type that was NOT provided fails as an unknown type,
;; never as a mangled mismatch -- byte-identical across compilers
(let ([entry (write-mod "xm-np.puf"
                        "(require \"shapes-np.puf\")"
                        "(define (describe [s : Shape]) : Sym"
                        "  (match s [Point 'dot] [(Circle _) 'round] [(Rect _ _) 'box]))"
                        "(println (describe (Circle 7)))")])
  (define-values (r p) (front-ends entry))
  (check-equal? (third r) "error: typecheck: unknown type Shape [xm-np.puf:2]\n")
  (check-equal? (second p) (third r))
  (check-equal? (first p) 1))

;; a cross-module type mismatch renders SOURCE spellings on both sides
(let ([entry (write-mod "xm-mismatch.puf"
                        "(require \"shapes.puf\")"
                        "(define (f [s : Shape]) : Int (area s))"
                        "(println (f 5))")])
  (define-values (r p) (front-ends entry))
  ;; the position is the CALL's line (the erroring form), not f's
  (check-equal? (third r) "error: typecheck: f: argument has type Int, expected Shape [xm-mismatch.puf:3]\n")
  (check-equal? (second p) (third r)))

;; define-type + define of one name is a (byte-identical) error
(let ([entry (write-mod "xm-collide.puf"
                        "(define-type Shape (Point))"
                        "(define Shape 5)"
                        "(println Shape)")])
  (define-values (r p) (front-ends entry))
  (check-equal? (third r) "error: typecheck: Shape is defined as both a type and a value [xm-collide.puf:2]\n")
  (check-equal? (second p) (third r)))

;; ...as is define-type of a builtin
(let ([entry (write-mod "xm-int.puf"
                        "(define-type Int (MkInt))"
                        "(println 1)")])
  (define-values (r p) (front-ends entry))
  (check-equal? (third r) "error: typecheck: define-type cannot redefine built-in type Int [xm-int.puf:1]\n")
  (check-equal? (second p) (third r)))

;; a cross-module exhaustiveness warning names Shape and Rect, not
;; their mangled spellings (compilation still succeeds)
(let ([entry (write-mod "xm-exh.puf"
                        "(require \"shapes.puf\")"
                        "(define (g [s : Shape]) : Int"
                        "  (match s [Point 0] [(Circle r) r]))"
                        "(println (g (Circle 5)))")])
  (define-values (r p) (front-ends entry))
  (check-equal? (third r) "typecheck warning: match on Shape is not exhaustive: missing Rect [xm-exh.puf:2]\n")
  (check-equal? (first r) 0)
  (check-equal? (third p) (third r)))

;; a cross-module cast failure blames with SOURCE spellings: the adt
;; desc displays Shape, the blame label names area -- on the reference
;; interpreter AND on a puffincc-compiled binary, byte-identically
(let ([entry (write-mod "xm-blame.puf"
                        "(require \"shapes.puf\")"
                        "(define (h s) (area s))"
                        "(println (h 99))")])
  ;; the blame carries the DECLARED boundary's position: area's
  ;; define in the exporting module (shapes.puf line 3)
  (define expected "puffin runtime error: cast: expected Shape, got 99 (blame: area's argument s [shapes.puf:3])\n")
  (let-values ([(ec so se) (run! puffin-cli "-i" (path->string entry))])
    (check-equal? se expected)
    (check-equal? ec 255))
  (define pbc (build-path dir "xm-blame.pbc"))
  (let-values ([(ec so se)
                (parameterize ([current-directory repo])
                  (run! puffincc (path->string entry) "-t" "bytecode"
                        "-o" (path->string pbc)))])
    (check-equal? ec 0))
  (let-values ([(ec so se) (run! puffin-vm (path->string pbc))])
    (check-equal? se expected)
    (check-equal? ec 255)))

;; positions (docs: file:line diagnostics): an unbound variable names
;; the erroring form's file and line, byte-identical across compilers
(let ([entry (write-mod "xm-unbound.puf"
                        "(define (ev e) (* e 2))"
                        "(println (evv 21))")])
  (define-values (r p) (front-ends entry))
  (check-equal? (third r) "error: typecheck: unbound variable evv [xm-unbound.puf:2]\n")
  (check-equal? (second p) (third r)))

(displayln "module error tests: all passed")
