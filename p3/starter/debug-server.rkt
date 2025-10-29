#lang racket

;; A debugging server which uses index.html and Vue.js to help
;; interactively debug programs.
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

;; helper: parse comma/space-separated ints
(define (string->ints s)
  (for/list ([tok (in-list (filter (λ (t) (positive? (string-length t)))
                                   (regexp-split #px"[\\s,]+" s)))])
    (string->number tok)))

;; compiles a user-uploaded file
(define (upload req)
  (define raw (request-post-data/raw req))
  (unless raw (error 'upload "POST had no plain-text body"))
  ;; content-type (may be #f)
  (define ctype
    (let ([h (headers-assq* #"content-type" (request-headers/raw req))])
      (and h (bytes->string/utf-8 (header-value h)))))
  (define j (bytes->jsexpr raw))
  (define prog-str (hash-ref j 'programSource (lambda () (error "no source..."))))
  (define sexpr (read (open-input-string prog-str)))
  (define inputs (hash-ref j 'input))
  ;; careful: avoid name clash with parameter input-file
  (define rel-input-file (hash-ref j 'inputFile ""))
  (define no-input-file? (equal? rel-input-file ""))
  (define input-file-path (and (not no-input-file?) (build-path HERE rel-input-file)))
  ;; (if necessary), build a temporary file to feed in as input
  (define temp-input-path
    (and no-input-file?
         (let ([p (make-temporary-file "tmp-debug-~a.in")])
           (with-output-to-file p
             (λ () (for-each (λ (n) (displayln n)) inputs))
             #:exists 'replace)
           p)))
  (define response
    (if (R3? sexpr)
        (parameterize ([input-file (if no-input-file? temp-input-path input-file-path)])
          (let ([trace (compile-verbose sexpr)]) ; inputs may be #f
            (trace->jsexpr trace)))
        (hasheq 'error "Input does not match R3? (see irs.rkt)")))
  (response/full
   200 #"OK" (current-seconds)
   #"application/json"
   (list (header #"Content-Type" #"application/json"))
   (list (jsexpr->bytes response))))

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
  (define (directory fmt-pass) (format "~a_~a_~a" program number fmt-pass))

  (define (read-sexpr/safe p)
    (with-handlers ([exn:fail? (λ (_) #f)])
      (call-with-input-file p
        (λ (in)
          (define v (read in))
          (if (eof-object? v) #f v)))))

  (define (read-deser/safe p)
    (with-handlers ([exn:fail? (λ (_) #f)])
      (call-with-input-file p
        (λ (in)
          (define v (read in))
          (if (eof-object? v) #f (deserialize v))))))

  ;; Correctly build: HERE/goldens/<base>.<suffix>
  (define (golden-path base suffix)
    (build-path HERE "goldens" (format "~a.~a" base suffix)))

  ;; Prefer deserialized value; fall back to raw text for old files.
  (define (read-ast-pretty base)
    (define out-ast-p (golden-path base "out-ast"))
    (define ast-p     (golden-path base "ast"))
    (cond
      [(file-exists? out-ast-p)
       (define vd (read-deser/safe out-ast-p))
       (cond
         [vd (safe-pretty vd)]
         [else
          (define vs (read-sexpr/safe out-ast-p))
          (if vs (safe-pretty vs) (read-trim out-ast-p))])]
      [(file-exists? ast-p)
       (define vd (read-deser/safe ast-p))
       (cond
         [vd (safe-pretty vd)]
         [else
          (define vs (read-sexpr/safe ast-p))
          (if vs (safe-pretty vs) (read-trim ast-p))])]
      [else "<missing>"]))

  (for/list ([p (in-list pass-names)])
    (define base     (directory p))
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
            'inputs    (map string->number
                                      (file->lines (build-path HERE (hash-ref it 'inputFile))))
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
       [_                         (index req)])]))

;; start server mounted at "/"
(define (run-server)
  (serve/servlet
   app
   #:servlet-path "/"
   #:servlet-regexp #rx""
   #:launch-browser? #f
   #:port 8000))

(module+ main
  (run-server))
