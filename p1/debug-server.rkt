#lang racket
(require web-server/servlet
         web-server/servlet-env
         web-server/dispatch
         racket/pretty
         json
         "compile.rkt")        ; <-- your solution

;; -------------------------------------------------------------------
;; Helpers
;; -------------------------------------------------------------------

(define (sexpr->string x)
  (pretty-format x #:mode 'write))

(define (maybe-load-golden pass-name)
  (define path (build-path "golden" (format "~a.sexp" pass-name)))
  (and (file-exists? path)
       (call-with-input-file path read)))

;; -------------------------------------------------------------------
;; HTTP handlers
;; -------------------------------------------------------------------

(define (->json-response jsexpr)
  (response
   200 #"OK" (current-seconds) #"application/json"
   '() (list (jsexpr->bytes jsexpr))))

(define (dispatch req)
  (define path (url-path (request-uri req)))
  (match path
    [(list "api" "compile")
     (define src-bytes (request-post-data/raw req))
     (define src-str   (bytes->string/utf-8 src-bytes))
     (define src-sexp  (with-input-from-string src-str read))
     (->json-response (hash 'passes (run-all-passes src-sexp)))]
    [else (next-dispatcher)]))

;; -------------------------------------------------------------------
;; Launch the server
;; -------------------------------------------------------------------

(serve/servlet
 dispatch
 #:launch-browser? #f
 #:listen-ip       #f          ; 0.0.0.0  if you want remote access
 #:port            8080
 #:stateless?      #t
 #:extra-files-paths (list (build-path (current-directory) "public")))

;; Visit:  http://localhost:8080/  (serves the SPA below)
