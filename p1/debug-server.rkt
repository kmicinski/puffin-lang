#lang racket
(require 
 "irs.rkt"
 "compile.rkt"
 web-server/servlet
 web-server/servlet-env
 web-server/http
 json) 

(define index-page (file->string "./index.html"))
 
(define (index _req)
  (response/full
   200                                  ; status
   #"OK"                                ; message
   (current-seconds)                    ; date
   #"text/html; charset=utf-8"          ; MIME type
   (list (header #"Content-Type" #"text/html; charset=utf-8"))
   (list (string->bytes/utf-8 index-page)))) ; body

(define (upload req)
  (define raw (request-post-data/raw req))
  (unless raw (error 'upload "POST had no plain-text body"))
  (define sexpr (read (open-input-string (bytes->string/utf-8 raw))))
  (define response
    (if (R1? sexpr)
        ;; valid program, compile it
        (compile-verbose sexpr)
        '(error "Input does not match R1? (see irs.rkt)"))) 
  (pretty-print response)
  (response/full
   200 #"OK" (current-seconds)
   #"application/json"
   (list (header #"Content-Type" #"application/json"))
   (list (jsexpr->bytes response))))

;; GET /  —— single-page app
(define (start req)
  (define method (request-method req))
  (define uri    (url->string (request-uri req)))
  (cond [(and (equal? method #"POST") (string=? uri "/"))  ; we post to "/"
         (upload req)]
        [else
         (index  req)]))

(module+ main
  (serve/servlet start
                 #:servlet-path "/"
                 #:servlet-regexp #rx""   ; accept *any* path, incl. /upload
                 #:launch-browser? #t
                 #:port 8000))



