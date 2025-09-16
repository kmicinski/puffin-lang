#lang racket

;; Compiler from R0 to C
;;(require "../interpreters/interp-r0.rkt")

(define (r0->c r0)
  (define (translate-expr e)
    (match e
      [(? fixnum? i) (number->string i)]
      ['(read) "read_int64()"]
      [`(- ,e) (format "(- ~a)" (translate-expr e))]
      [`(+ ,e0 ,e1) (format "(~a + ~a)"
                            (translate-expr e0)
                            (translate-expr e1))]))
  (match r0
    [`(program ,e)
     (format (string-append "#include \"runtime.h\"\n\n"
                            "int main(int argc, char **argv) {\n"
                            "    print_int64(~a);\n"
                            "}\n")
             (translate-expr e))]))

(define file-path
  (command-line #:args (filename) filename))

(define (main)
  (define source-tree (with-input-from-file file-path read))
  (displayln (r0->c source-tree)))

(main)

 
