#lang racket

;; Puffin -- tools/lsp/test-lsp.rkt: scripted end-to-end session
;; against bin/puffin-lsp over stdio. Run: racket tools/lsp/test-lsp.rkt
;;
;; Session: initialize -> didOpen a valid corpus program (expect zero
;; diagnostics) -> didOpen a reader-error buffer (expect a positioned
;; diagnostic) -> didOpen a semantic-error buffer (expect a diagnostic
;; positioned at the offending symbol) -> hover over `car` (expect its
;; manifest doc) -> completion (expect car/cdr) -> definition +
;; documentSymbol -> shutdown/exit (expect clean termination).

(require json racket/runtime-path)

(define-runtime-path lsp-bin "../../bin/puffin-lsp")
(define-runtime-path cek-file "../../src/test-programs/pl-cek.scm")

(define-values (proc from-server to-server _err)
  (subprocess #f #f (current-error-port) (path->string lsp-bin)))

;; kill a hung run rather than hanging CI
(void (thread (λ () (sleep 60)
                (eprintf "test-lsp: TIMEOUT\n")
                (subprocess-kill proc #t)
                (exit 1))))

(define (send! js)
  (define body (jsexpr->bytes js))
  (write-bytes (string->bytes/utf-8
                (format "Content-Length: ~a\r\n\r\n" (bytes-length body)))
               to-server)
  (write-bytes body to-server)
  (flush-output to-server))

(define (request! id method params)
  (send! (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params)))
(define (notify! method params)
  (send! (hasheq 'jsonrpc "2.0" 'method method 'params params)))

(define (recv!)
  (let loop ([len #f])
    (define line (read-line from-server 'any))
    (cond
      [(eof-object? line) eof]
      [(string=? (string-trim line) "")
       (if len
           (let ([body (read-bytes len from-server)])
             (if (eof-object? body) eof (bytes->jsexpr body)))
           (loop #f))]
      [else
       (define m (regexp-match #px"^[Cc]ontent-[Ll]ength:\\s*([0-9]+)" line))
       (loop (if m (string->number (cadr m)) len))])))

;; Skip interleaved notifications until `pred` matches.
(define (recv-until pred what)
  (let loop ()
    (define msg (recv!))
    (cond [(eof-object? msg) (fail! (format "EOF while waiting for ~a" what)) #f]
          [(pred msg) msg]
          [else (loop)])))

(define (response-for id)
  (recv-until (λ (m) (equal? (hash-ref m 'id #f) id)) (format "response id=~a" id)))
(define (diagnostics-for uri)
  (define msg
    (recv-until (λ (m) (and (equal? (hash-ref m 'method #f) "textDocument/publishDiagnostics")
                            (equal? (hash-ref (hash-ref m 'params (hasheq)) 'uri #f) uri)))
                (format "diagnostics for ~a" uri)))
  (and msg (hash-ref (hash-ref msg 'params) 'diagnostics)))

(define failures 0)
(define (fail! msg)
  (set! failures (add1 failures))
  (printf "FAIL  ~a\n" msg))
(define (check! ok? msg [got #f])
  (if ok?
      (printf "ok    ~a\n" msg)
      (fail! (format "~a~a" msg (if got (format "  [got: ~a]" (jsexpr->string got)) "")))))

(define (did-open! uri text)
  (notify! "textDocument/didOpen"
           (hasheq 'textDocument
                   (hasheq 'uri uri 'languageId "puffin" 'version 1 'text text))))

(define (tdp uri line ch)
  (hasheq 'textDocument (hasheq 'uri uri)
          'position (hasheq 'line line 'character ch)))

;; --- 1. initialize --------------------------------------------------
(request! 1 "initialize" (hasheq 'processId 'null 'rootUri 'null 'capabilities (hasheq)))
(define init-resp (response-for 1))
(define caps (hash-ref (hash-ref init-resp 'result (hasheq)) 'capabilities (hasheq)))
(check! (equal? (hash-ref caps 'textDocumentSync #f) 1) "initialize: full-document sync" caps)
(check! (equal? (hash-ref caps 'hoverProvider #f) #t) "initialize: hoverProvider")
(check! (hash? (hash-ref caps 'completionProvider #f)) "initialize: completionProvider")
(check! (equal? (hash-ref caps 'definitionProvider #f) #t) "initialize: definitionProvider")
(check! (equal? (hash-ref caps 'documentSymbolProvider #f) #t) "initialize: documentSymbolProvider")
(notify! "initialized" (hasheq))

;; --- 2. valid corpus program: zero diagnostics ----------------------
(define cek-uri "file:///test/pl-cek.puf")
(did-open! cek-uri (file->string cek-file))
(define cek-diags (diagnostics-for cek-uri))
(check! (null? cek-diags) "didOpen pl-cek.scm: zero diagnostics" cek-diags)

;; --- 3. reader error: positioned diagnostic -------------------------
(define bad-uri "file:///test/bad.puf")
(did-open! bad-uri "(define (f")
(define bad-diags (diagnostics-for bad-uri))
(check! (= (length bad-diags) 1) "didOpen \"(define (f\": one diagnostic" bad-diags)
(when (pair? bad-diags)
  (define r (hash-ref (car bad-diags) 'range (hasheq)))
  (define s (hash-ref r 'start (hasheq)))
  (check! (and (number? (hash-ref s 'line #f)) (number? (hash-ref s 'character #f)))
          "reader diagnostic has a position" r)
  (check! (regexp-match? #rx"read" (hash-ref (car bad-diags) 'message ""))
          "reader diagnostic message mentions the reader" (car bad-diags)))

;; --- 4. semantic (desugar) error: positioned at the symbol ----------
;; (car x y) has the wrong arity; the message names `car`, which first
;; occurs at line 1, character 3.
(define sem-uri "file:///test/sem.puf")
(did-open! sem-uri "(define (g x y)\n  (car x y))\n(println (g 1 2))\n")
(define sem-diags (diagnostics-for sem-uri))
(check! (= (length sem-diags) 1) "arity error: one diagnostic" sem-diags)
(when (pair? sem-diags)
  (define s (hash-ref (hash-ref (car sem-diags) 'range (hasheq)) 'start (hasheq)))
  (check! (and (equal? (hash-ref s 'line #f) 1) (equal? (hash-ref s 'character #f) 3))
          "arity diagnostic points at `car` (line 1, char 3)" (car sem-diags)))

;; --- 5. hover over a stdlib prim ------------------------------------
(define hov-uri "file:///test/hover.puf")
(define hov-text "(define (g p)\n  (car p))\n(println (g (cons 1 2)))\n")
(did-open! hov-uri hov-text)
(check! (null? (diagnostics-for hov-uri)) "hover buffer: zero diagnostics")
;; line 1 is "  (car p))": char 4 sits inside `car`
(request! 2 "textDocument/hover" (tdp hov-uri 1 4))
(define hov (hash-ref (response-for 2) 'result 'null))
(define hov-val (if (hash? hov)
                    (hash-ref (hash-ref hov 'contents (hasheq)) 'value "")
                    ""))
(check! (regexp-match? #rx"car" hov-val) "hover(car): names the prim" hov)
(check! (regexp-match? #rx"First component of a pair" hov-val)
        "hover(car): manifest doc string present" hov)
;; hover over a buffer define
(request! 3 "textDocument/hover" (tdp hov-uri 2 10))
(define hovg (hash-ref (response-for 3) 'result 'null))
(check! (and (hash? hovg)
             (regexp-match? #rx"\\(define \\(g p\\)"
                            (hash-ref (hash-ref hovg 'contents (hasheq)) 'value "")))
        "hover(g): shows the define head line" hovg)

;; --- 6. completion ---------------------------------------------------
(request! 4 "textDocument/completion" (tdp hov-uri 1 4))
(define comp (hash-ref (response-for 4) 'result '()))
(define labels (map (λ (i) (hash-ref i 'label "")) comp))
(check! (member "car" labels) "completion: car present")
(check! (member "cdr" labels) "completion: cdr present")
(check! (member "map" labels) "completion: prelude map present")
(check! (member "g" labels) "completion: buffer define g present")
(define car-item (findf (λ (i) (equal? (hash-ref i 'label "") "car")) comp))
(check! (and car-item (equal? (hash-ref car-item 'kind #f) 3))
        "completion: car is kind Function" car-item)

;; --- 7. definition + documentSymbol ----------------------------------
;; `g` is used at line 2, char 10
(request! 5 "textDocument/definition" (tdp hov-uri 2 10))
(define defloc (hash-ref (response-for 5) 'result 'null))
(check! (and (hash? defloc)
             (equal? (hash-ref defloc 'uri #f) hov-uri)
             (equal? (hash-ref (hash-ref (hash-ref defloc 'range (hasheq)) 'start (hasheq)) 'line #f) 0))
        "definition(g): points at line 0 of the buffer" defloc)
(request! 6 "textDocument/documentSymbol"
          (hasheq 'textDocument (hasheq 'uri hov-uri)))
(define syms (hash-ref (response-for 6) 'result '()))
(check! (and (= (length syms) 1)
             (equal? (hash-ref (car syms) 'name #f) "g")
             (equal? (hash-ref (car syms) 'kind #f) 12))
        "documentSymbol: [g] as Function" syms)

;; --- 8. shutdown / exit ----------------------------------------------
(request! 7 "shutdown" (hasheq))
(define shut (response-for 7))
(check! (hash-has-key? shut 'result) "shutdown: acknowledged" shut)
(notify! "exit" (hasheq))
(subprocess-wait proc)
(check! (equal? (subprocess-status proc) 0) "exit: server terminated with status 0")

(printf "~a\n" (if (zero? failures) "ALL TESTS PASSED" (format "~a FAILURE(S)" failures)))
(exit (if (zero? failures) 0 1))
