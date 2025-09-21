#lang racket

(require "main.rkt")
(require "system.rkt") ;; list of passes, system-relevant details, etc.
(require "irs.rkt")
(require "compile.rkt")
(require "interpreters.rkt")
(require json)
(require racket/runtime-path
         racket/serialize
         web-server/servlet
         web-server/servlet-env
         web-server/http)

(provide (all-defined-out))

;;
;; Debug server infrastructure
;;
(define-runtime-path HERE "./")
(define-runtime-path TEST "./test")
(define-runtime-path TEST_PROGRAMS "./test-programs")

(define (index _req)
  (define ix (build-path HERE "index.html"))
  (response/full
   200                                  ; status
   #"OK"                                ; message
   (current-seconds)                    ; date
   #"text/html; charset=utf-8"          ; MIME type
   (list (header #"Content-Type" #"text/html; charset=utf-8"))
   (list (string->bytes/utf-8 (file->string ix)))))

(define (upload req)
  (define raw (request-post-data/raw req))
  (unless raw (error 'upload "POST had no plain-text body"))
  (define sexpr (read (open-input-string (bytes->string/utf-8 raw))))
  (define response
    (if (R1? sexpr)
        ;; valid program, compile it
        (let ([compilation-trace (compile-verbose sexpr)])
          (trace->jsexpr compilation-trace))
        (hasheq 'error "Input does not match R1? (see irs.rkt)")))
  (pretty-print response)
  (response/full
   200 #"OK" (current-seconds)
   #"application/json"
   (list (header #"Content-Type" #"application/json"))
   (list (jsexpr->bytes response))))


;; Small helpers
(define (read-serialized p)
  (with-input-from-file p (λ () (deserialize (read)))))

(define (read-trim p)
  (string-trim (file->string p)))

(define (safe-pretty v)
  (if (string? v) v (pretty-format v)))

;; dir = e.g., path "test/r1-5_native_3"
(define (parse-test-dir dir)
  (define name (path->string (file-name-from-path dir)))
  (match (regexp-match #px"^(.*)_native_(\\d+)$" name)
    [(list _ prog n)
     (define cfg (build-path dir "testdata.cfg"))
     (pretty-print (with-input-from-file cfg read)) 
     (and (file-exists? cfg)
          (let* ([cfgv (with-input-from-file cfg read)]
                 [mode (list-ref cfgv 0)]
                 [prog-file (list-ref cfgv 1)]
                 [in   (list-ref cfgv 2)]
                 [gld  (list-ref cfgv 3)])
            (and (or (eq? mode 'native)
                     (and (string? mode) (string-ci=? mode "native")))
                 (hash 'id         name
                       'program    prog
                       'number     (string->number n)
                       'progFile   prog-file
                       'inputFile  in
                       'goldenFile gld))))]
    [_ #f]))

(define (list-native-tests)
  (filter values
          (for/list ([d (in-list (directory-list TEST))])
            (define base (file-name-from-path d))
            (if (regexp-match? #px"_native_\\d+$" (path->string base))
                (parse-test-dir (build-path TEST base))
                #f))))

(define (golden-trace program number)
  (define (b fmt-pass) (format "~a_~a_~a" program number fmt-pass))
  (define (golden-path base ext)
    (build-path "goldens" (string-append base "." ext)))

  ;; Try to read an s-expression; if it fails, return #f.
  (define (read-sexpr/safe p)
    (with-handlers ([exn:fail? (λ (_) #f)])
      (call-with-input-file p (λ (in)
        (define v (read in))
        (if (eof-object? v) #f v)))))

  ;; Read an AST file (prefer *.out-ast, fallback to *.ast).
  (define (read-ast-pretty base)
    (define out-ast-p (golden-path base "out-ast"))
    (define ast-p     (golden-path base "ast"))
    (cond
      [(file-exists? out-ast-p)
       (define v (read-sexpr/safe out-ast-p))
       (if v (safe-pretty v) (read-trim out-ast-p))]
      [(file-exists? ast-p)
       (define v (read-sexpr/safe ast-p))
       (if v (safe-pretty v) (read-trim ast-p))]
      [else "<missing>"]))

  (for/list ([p (in-list pass-names)])
    (define base     (b p))
    (define stdout-p (golden-path base "stdout"))
    (define interp-p (golden-path base "interp"))
    (hash
      'pass-name     p
      'pretty-output (read-ast-pretty base)
      'stdout        (if (file-exists? stdout-p) (read-trim stdout-p) "")
      'interp        (if (file-exists? interp-p) (read-trim interp-p) "<none>"))))

;; GET /tests -> brief list with enough to populate the UI (and preload program)
(define (handle-tests _req)
  (define items
    (for/list ([it (in-list (list-native-tests))])
      (hash 'id        (hash-ref it 'id)
            'program   (hash-ref it 'program)
            'number    (hash-ref it 'number)
            'progFile  (hash-ref it 'progFile)
            'inputFile (hash-ref it 'inputFile)
            'golden    (hash-ref it 'goldenFile)
            'programSource (file->string (build-path HERE (hash-ref it 'progFile))))))
  (response/full
   200 #"OK" (current-seconds) #"application/json"
   (list (header #"Content-Type" #"application/json"))
   (list (jsexpr->bytes items))))

;; GET /golden-trace?id=<dirName> -> instructor pass trace
(define (handle-golden-trace req)
  (define url (request-uri req))
  (define id  (let ([qs (url-query url)])
                (for/or ([p (in-list qs)])
                  (and (string-ci=? (symbol->string (car p)) "id") (cdr p)))))
  (unless id (error 'golden-trace "missing ?id=…"))
  (match (regexp-match #px"^(.*)_native_(\\d+)$" id)
    [(list _ prog n)
     (define trace (golden-trace prog n))
     (pretty-print trace)
     (response/full
      200 #"OK" (current-seconds) #"application/json"
      (list (header #"Content-Type" #"application/json"))
      (list (jsexpr->bytes trace)))]
    [_ (response/full 400 #"Bad Request" (current-seconds) #"text/plain" '() (list #"bad id"))]))

(define (app req)
  (define path (url-path (request-uri req)))
  (cond
    [(bytes=? (request-method req) #"POST")
     (upload req)]
    [else
     (match (map path/param-path path)
       [(list "tests")            (handle-tests req)]
       [(list "golden-trace")     (handle-golden-trace req)]
       [_                            (index req)])]))

;; start server mounted at "/"
(define (run-server)
  (serve/servlet
   app
   #:servlet-path "/"
   #:servlet-regexp #rx""
   #:launch-browser? #t
   #:port 8000))

(module+ main
  (run-server))
