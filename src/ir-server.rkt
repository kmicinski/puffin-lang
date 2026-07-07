#lang racket

;; Puffin -- ir-server.rkt: the local pipeline-trace server behind
;; the web visualizer (the descendant of the class debug-server.rkt).
;;
;;   racket src/ir-server.rkt                  serve on :8899
;;   racket src/ir-server.rkt -p 9000          another port
;;   racket src/ir-server.rkt --dump prog.puf out.json [-t target]
;;                                             write one trace as JSON
;;                                             (used for the bundled
;;                                             web demo trace)
;;
;; API (CORS-open, for the vite dev server / built app):
;;   POST /trace   body: {"source": "...", "target": "arm64"|"x86-64"}
;;                 -> the pipeline JSON (see ir-json.rkt)
;;   GET  /passes  -> pass names for the default target

(require web-server/servlet web-server/servlet-env)
(require net/url)
(require json)
(require racket/runtime-path)
(require "system.rkt")
(require "irs.rkt")
(require "modules.rkt")
(require "compile.rkt")
(require "interpreters.rkt")
(require "main.rkt")
(require "backend-x86.rkt")
(require "ir-json.rkt")

(define-runtime-path here ".")

(define (render-lines-for tgt)
  (match tgt
    ['x86-64 render-lines-x86]
    ['arm64 (dynamic-require (build-path here "backend-arm64.rkt") 'render-lines-arm64)]))

;; Compile source text through the full chain for `tgt`, returning
;; the pipeline jsexpr (or an error jsexpr). `files` is an optional
;; virtual file map (hash of path-string -> source-string) for module
;; programs: it is materialized in a temp directory and resolved
;; through the module front pass, entry main.puf.
(define (trace-source source-text tgt olvl [files #f])
  (with-handlers ([exn:fail? (λ (e) (hash 'error (exn-message e)))])
    (define (read-forms-from-string s)
      (with-input-from-string s
        (λ () (let loop ([acc '()])
                (define f (read))
                (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))
    (define forms
      (cond
        [files
         (define dir (build-path (find-system-path 'temp-dir)
                                 (format "puffin-trace-~a" (current-milliseconds))))
         (make-directory* dir)
         (for ([(name src) (in-hash files)])
           ;; virtual paths are flat names; refuse anything that escapes
           (define name-str (if (symbol? name) (symbol->string name) name))
           (when (regexp-match? #rx"\\.\\.|/" name-str)
             (error 'trace "bad file name: ~a" name-str))
           (with-output-to-file (build-path dir name-str) #:exists 'replace
             (λ () (display src))))
         (begin0 (resolve-modules (build-path dir "main.puf"))
                 (delete-directory/files dir))]
        [else
         (define raw (read-forms-from-string source-text))
         (if (module-forms? raw)
             ;; a lone source using require/provide resolves against itself
             (let ([dir (build-path (find-system-path 'temp-dir)
                                    (format "puffin-trace-~a" (current-milliseconds)))])
               (make-directory* dir)
               (with-output-to-file (build-path dir "main.puf") #:exists 'replace
                 (λ () (display source-text)))
               (begin0 (resolve-modules (build-path dir "main.puf"))
                       (delete-directory/files dir)))
             (match raw
               [`((program ,inner ...)) inner]
               [_ raw]))]))
    (define program `(program ,@(prelude-forms forms) ,@forms))
    (parameterize ([target tgt]
                   [optimize-level olvl]
                   [write-stdout-mode #f]
                   [verbose-mode #f])
      (define trace
        (run-chain program
                   (map first (all-passes))
                   (map second (all-passes))
                   (map third (all-passes))
                   (map fourth (all-passes))
                   (map (λ (_) (λ (p in) "")) (all-passes)) ;; no interpretation
                   '()))
      (define failed (findf (λ (e) (hash-has-key? e 'error)) trace))
      (if failed
          (hash 'error (format "pass ~a crashed: ~a"
                               (hash-ref failed 'pass-name)
                               (hash-ref failed 'error "")))
          (trace->pipeline-jsexpr trace source-text (symbol->string tgt)
                                  (render-lines-for tgt))))))

;; ---------------------------------------------------------------------
;; HTTP plumbing
;; ---------------------------------------------------------------------

(define (cors-headers)
  (list (make-header #"Access-Control-Allow-Origin" #"*")
        (make-header #"Access-Control-Allow-Headers" #"content-type")))

(define (json-response jsexpr)
  (response/full 200 #"OK" (current-seconds) #"application/json"
                 (cors-headers)
                 (list (jsexpr->bytes jsexpr))))

(define (start req)
  (match (list (request-method req) (map path/param-path (url-path (request-uri req))))
    [(list #"OPTIONS" _)
     (response/full 204 #"No Content" (current-seconds) #"text/plain" (cors-headers) '())]
    [(list #"POST" (list "trace"))
     (define body (bytes->jsexpr (request-post-data/raw req)))
     (define tgt (match (hash-ref body 'target "host")
                   ["x86-64" 'x86-64]
                   ["arm64" 'arm64]
                   [_ (default-target)]))
     (define olvl (match (hash-ref body 'optimize 1)
                    [(and (? exact-integer? n) (? (λ (n) (<= 0 n 2)))) n]
                    [_ 1]))
     (define files
       (match (hash-ref body 'files 'missing)
         [(? hash? h) h]
         [_ #f]))
     (json-response (trace-source (hash-ref body 'source "") tgt olvl files))]
    [(list #"GET" (list "passes"))
     (json-response (hash 'passes (parameterize ([target (default-target)])
                                    (map second (all-passes)))))]
    [_ (response/full 404 #"Not Found" (current-seconds) #"text/plain" (cors-headers)
                      (list #"not found"))]))

(define port (make-parameter 8899))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (match args
    [(list "--dump" prog out rest ...)
     (define tgt (match rest [(list "-t" t) (string->symbol t)] [_ (default-target)]))
     (define jsexpr (trace-source (file->string prog) tgt 1))
     (with-output-to-file out (λ () (write-json jsexpr)) #:exists 'replace)
     (displayln (format "wrote ~a (~a passes)" out
                        (if (hash-has-key? jsexpr 'passes)
                            (length (hash-ref jsexpr 'passes))
                            "ERROR")))]
    [_
     (match args
       [(list "-p" p) (port (string->number p))]
       [_ (void)])
     (displayln (format "Puffin pipeline server on http://localhost:~a  (POST /trace)" (port)))
     (serve/servlet start
                    #:port (port)
                    #:servlet-regexp #rx""
                    #:command-line? #t)]))
