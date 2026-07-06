#lang racket

;; Puffin -- tools/lsp/server.rkt: a Language Server Protocol server
;; over stdio (JSON-RPC 2.0, Content-Length framing, implemented by
;; hand below).
;;
;; Capabilities:
;;   - full-document sync (didOpen / didChange / didClose)
;;   - diagnostics on open/change, published via
;;     textDocument/publishDiagnostics:
;;       1. a read-syntax pass over the buffer -- reader errors carry
;;          exact line/column srclocs, so those diagnostics are
;;          precisely positioned;
;;       2. if reading succeeds, the compiler's front-end passes
;;          (desugar -> shrink -> uniqueify from src/compile.rkt) run
;;          on the program, wrapped exactly the way src/main.rkt
;;          wraps it (prelude injection + (program ...)). The AST
;;          carries no srclocs, so a pass error is positioned at the
;;          first textual occurrence in the buffer of any symbol the
;;          error message names, else at position 0.
;;   - hover: stdlib primitives (from the src/stdlib.rkt manifest:
;;     signature + doc string), prelude functions and buffer-local
;;     defines (their (define ...) head line)
;;   - completion (trigger "("): stdlib prims + prelude functions +
;;     top-level defines in the buffer
;;   - definition + documentSymbol over the buffer's top-level defines
;;
;; Launch: bin/puffin-lsp (a shell wrapper over this module).

(require json
         racket/runtime-path
         (only-in "../../src/compile.rkt" desugar shrink uniqueify)
         (only-in "../../src/main.rkt" prelude-forms)
         (only-in "../../src/stdlib.rkt"
                  stdlib-primitives
                  prim-spec-name prim-spec-arity prim-spec-surface? prim-spec-doc))

(define-runtime-path prelude-path "../../src/prelude.puf")

;; ---------------------------------------------------------------------
;; Protocol ports. Everything the server *says* goes through
;; proto-out; current-output-port is re-pointed at stderr so that any
;; stray (display ...) from a compiler pass cannot corrupt the framing.
;; ---------------------------------------------------------------------

(define proto-in  (current-input-port))
(define proto-out (current-output-port))
(current-output-port (current-error-port))

;; ---------------------------------------------------------------------
;; Content-Length framing
;; ---------------------------------------------------------------------

;; Read one framed JSON-RPC message; eof on end of input.
(define (read-lsp-message)
  (let loop ([len #f])
    (define line (read-line proto-in 'any))
    (cond
      [(eof-object? line) eof]
      [(string=? (string-trim line) "")
       (cond
         [len
          (define body (read-bytes len proto-in))
          (if (or (eof-object? body) (< (bytes-length body) len))
              eof
              (with-handlers ([exn:fail? (λ (_) 'bad-json)])
                (bytes->jsexpr body)))]
         [else (loop #f)])] ;; stray blank line before headers
      [else
       (define m (regexp-match #px"^[Cc]ontent-[Ll]ength:\\s*([0-9]+)" line))
       (loop (if m (string->number (cadr m)) len))])))

(define (write-lsp-message js)
  (define body (jsexpr->bytes js))
  (write-bytes (string->bytes/utf-8
                (format "Content-Length: ~a\r\n\r\n" (bytes-length body)))
               proto-out)
  (write-bytes body proto-out)
  (flush-output proto-out))

(define (respond id result)
  (write-lsp-message (hasheq 'jsonrpc "2.0" 'id id 'result result)))

(define (respond-error id code msg)
  (write-lsp-message
   (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code code 'message msg))))

(define (notify method params)
  (write-lsp-message (hasheq 'jsonrpc "2.0" 'method method 'params params)))

;; ---------------------------------------------------------------------
;; Text / position utilities. LSP positions are 0-based line and
;; character; Racket srclocs are 1-based line, 0-based column.
;; ---------------------------------------------------------------------

(define (line-start-offsets text)
  (define n (string-length text))
  (let loop ([i 0] [acc '(0)])
    (cond [(>= i n) (list->vector (reverse acc))]
          [(char=? (string-ref text i) #\newline) (loop (add1 i) (cons (add1 i) acc))]
          [else (loop (add1 i) acc)])))

(define (pos->offset text line ch)
  (define starts (line-start-offsets text))
  (define l (min (max line 0) (sub1 (vector-length starts))))
  (define start (vector-ref starts l))
  (define line-end
    (if (< (add1 l) (vector-length starts))
        (sub1 (vector-ref starts (add1 l)))
        (string-length text)))
  (min (+ start (max ch 0)) line-end))

(define (offset->pos text off)
  (define starts (line-start-offsets text))
  (let loop ([l (sub1 (vector-length starts))])
    (if (or (zero? l) (<= (vector-ref starts l) off))
        (values l (- off (vector-ref starts l)))
        (loop (sub1 l)))))

(define (line-text text l)
  (define starts (line-start-offsets text))
  (cond
    [(or (< l 0) (>= l (vector-length starts))) ""]
    [else
     (define start (vector-ref starts l))
     (define end (if (< (add1 l) (vector-length starts))
                     (sub1 (vector-ref starts (add1 l)))
                     (string-length text)))
     (substring text start end)]))

;; Puffin identifiers: Scheme symbols -- everything up to a delimiter
;; ()[]{}"'`,; or whitespace.
(define id-delimiters (string->list "()[]{}\"'`,;"))
(define (id-char? c)
  (and (not (char-whitespace? c)) (not (memv c id-delimiters))))

;; The identifier around offset `off` (also looks one char left, for
;; a cursor sitting just after a word). Three values: word (or #f),
;; start offset, end offset.
(define (word-at text off)
  (define n (string-length text))
  (define i (cond [(and (< off n) (id-char? (string-ref text off))) off]
                  [(and (> off 0) (<= off n) (id-char? (string-ref text (sub1 off)))) (sub1 off)]
                  [else #f]))
  (cond
    [(not i) (values #f 0 0)]
    [else
     (define start (let loop ([s i]) (if (and (> s 0) (id-char? (string-ref text (sub1 s)))) (loop (sub1 s)) s)))
     (define end   (let loop ([e (add1 i)]) (if (and (< e n) (id-char? (string-ref text e))) (loop (add1 e)) e)))
     (values (substring text start end) start end)]))

;; First delimited occurrence of `word` in text, or #f.
(define (find-delimited text word)
  (define n (string-length text))
  (define rx (regexp (regexp-quote word)))
  (let loop ([from 0])
    (define m (and (<= from n) (regexp-match-positions rx text from)))
    (cond
      [(not m) #f]
      [else
       (define b (caar m))
       (define e (cdar m))
       (if (and (or (zero? b) (not (id-char? (string-ref text (sub1 b)))))
                (or (= e n) (not (id-char? (string-ref text e)))))
           b
           (loop (add1 b)))])))

(define (range-jsexpr l0 c0 l1 c1)
  (hasheq 'start (hasheq 'line l0 'character c0)
          'end   (hasheq 'line l1 'character c1)))

;; ---------------------------------------------------------------------
;; Documents: uri -> text
;; ---------------------------------------------------------------------

(define documents (make-hash))

;; ---------------------------------------------------------------------
;; Top-level define extraction (positions included). Primary path is
;; read-syntax (exact lines/columns); if the buffer doesn't read, a
;; line-regexp scan still finds the defines, so hover/completion/
;; definition keep working while the user is mid-edit.
;; ---------------------------------------------------------------------

(struct defn (name fun? line col head) #:transparent)

(define (head-line-of text l)
  (string-trim (line-text text l) #:left? #f))

(define (defines-from-syntax text)
  (define in (open-input-string text))
  (port-count-lines! in)
  (define (stx->defns stx)
    (define (mk name fun?)
      (list (defn name fun?
              (sub1 (or (syntax-line stx) 1))
              (or (syntax-column stx) 0)
              (head-line-of text (sub1 (or (syntax-line stx) 1))))))
    (match (syntax->datum stx)
      [`(define (,(? symbol? f) . ,_) . ,_) (mk f #t)]
      [`(define ,(? symbol? x) . ,_)        (mk x #f)]
      [`(program . ,_)
       ;; class-style single (program ...) wrapper: descend
       (append-map stx->defns (cdr (or (syntax->list stx) (list stx))))]
      [_ '()]))
  (let loop ([acc '()])
    (define stx (read-syntax 'buffer in))
    (if (eof-object? stx)
        (reverse acc)
        (loop (append (reverse (stx->defns stx)) acc)))))

(define defn-line-rx
  #px"^[ \t]*\\(define\\s+(\\()?[ \t]*([^\\s()\\[\\]{}\"'`,;]+)")

(define (defines-from-regex text)
  (for/fold ([acc '()] #:result (reverse acc))
            ([l (in-lines (open-input-string text))]
             [ln (in-naturals)])
    (define m (regexp-match defn-line-rx l))
    (if m
        (cons (defn (string->symbol (caddr m))
                (and (cadr m) #t)
                ln
                (- (string-length l) (string-length (string-trim l #:right? #f)))
                (string-trim l #:left? #f))
              acc)
        acc)))

(define (buffer-defines text)
  (with-handlers ([exn:fail? (λ (_) (defines-from-regex text))])
    (defines-from-syntax text)))

(define (find-define text word)
  (findf (λ (d) (string=? (symbol->string (defn-name d)) word))
         (buffer-defines text)))

;; ---------------------------------------------------------------------
;; The hover/completion database: stdlib manifest + prelude defines
;; ---------------------------------------------------------------------

(define surface-prims
  (filter prim-spec-surface? stdlib-primitives))

(define stdlib-by-name
  (for/hash ([s surface-prims])
    (values (symbol->string (prim-spec-name s)) s)))

(define (prim-signature s)
  (define n (prim-spec-arity s))
  (if (zero? n)
      (format "(~a)" (prim-spec-name s))
      (format "(~a ~a)" (prim-spec-name s)
              (string-join (for/list ([i (in-range n)]) (format "x~a" (add1 i))) " "))))

(define prelude-defines
  (with-handlers ([exn:fail? (λ (_) '())])
    (defines-from-syntax (file->string prelude-path))))

(define prelude-by-name
  (for/hash ([d prelude-defines])
    (values (symbol->string (defn-name d)) d)))

;; ---------------------------------------------------------------------
;; Diagnostics
;; ---------------------------------------------------------------------

(define (diagnostic l0 c0 l1 c1 msg)
  (hasheq 'range (range-jsexpr l0 c0 l1 c1)
          'severity 1
          'source "puffin"
          'message msg))

(define (reader-exn->diagnostic text e)
  (define locs (if (exn:srclocs? e)
                   ((exn:srclocs-accessor e) e)
                   '()))
  (define loc (and (pair? locs) (car locs)))
  (cond
    [(and loc (srcloc-line loc))
     (define l (sub1 (srcloc-line loc)))
     (define c (or (srcloc-column loc) 0))
     (define span (max (or (srcloc-span loc) 1) 1))
     (diagnostic l c l (+ c span) (exn-message e))]
    [(and loc (srcloc-position loc))
     (define-values (l c) (offset->pos text (sub1 (srcloc-position loc))))
     (diagnostic l c l (add1 c) (exn-message e))]
    [else (diagnostic 0 0 0 0 (exn-message e))]))

;; Words in an error message that are almost never the identifier the
;; user wrote (keywords, pass names, message prose): skip them when
;; hunting for a buffer position.
(define message-stopwords
  (for/set ([w '("define" "lambda" "let" "let*" "letrec" "if" "cond" "case"
                 "when" "unless" "begin" "set!" "quote" "quasiquote" "while"
                 "match" "list" "and" "or" "not" "else"
                 "desugar" "shrink" "uniqueify" "collect-globals" "error"
                 "program" "expects" "expected" "got" "arguments" "argument"
                 "number" "even" "odd" "bad" "unsupported" "quoted" "datum"
                 "formals" "reserved" "for" "the" "entry" "point" "in" "no"
                 "matching" "clause" "clauses" "of" "an" "a" "is" "to" "..." "_")])
    w))

;; A front-end pass raised `msg` (no srclocs in the AST): point at the
;; first textual occurrence of an identifier the message names. Tokens
;; are tried in message order (stopwords skipped), so the symbol the
;; pass complains about first -- usually the offending operator --
;; wins over incidental subterm mentions.
(define (message->diagnostic text msg)
  (define tokens
    (remove-duplicates
     (filter (λ (t) (and (positive? (string-length t))
                         (not (regexp-match? #px"^[0-9]+$" t))
                         (not (set-member? message-stopwords t))))
             (regexp-split #px"[\\s()\\[\\]{}\"'`,;:]+" msg))))
  (define best
    (for/or ([t tokens])
      (define off (find-delimited text t))
      (and off (cons off t))))
  (cond
    [best
     (define-values (l c) (offset->pos text (car best)))
     (diagnostic l c l (+ c (string-length (cdr best))) msg)]
    [else (diagnostic 0 0 0 0 msg)]))

;; The buffer's diagnostics: reader errors (exact positions), then the
;; compiler front-end (desugar -> shrink -> uniqueify), wrapped the way
;; src/main.rkt's read-program-file wraps a program.
(define (analyze text)
  (define in (open-input-string text))
  (port-count-lines! in)
  (define read-result
    (with-handlers ([exn:fail? (λ (e) e)])
      (let loop ([acc '()])
        (define d (read in))
        (if (eof-object? d) (reverse acc) (loop (cons d acc))))))
  (cond
    [(exn? read-result)
     (list (reader-exn->diagnostic text read-result))]
    [else
     (define forms
       (match read-result
         [`((program ,inner ...)) inner]
         [fs fs]))
     (with-handlers ([exn:fail? (λ (e) (list (message->diagnostic text (exn-message e))))])
       (define prog `(program ,@(prelude-forms forms) ,@forms))
       (uniqueify (shrink (desugar prog)))
       '())]))

(define (publish-diagnostics! uri text)
  (define diags
    (with-handlers ([exn:fail? (λ (_) '())])
      (analyze text)))
  (notify "textDocument/publishDiagnostics"
          (hasheq 'uri uri 'diagnostics diags)))

;; ---------------------------------------------------------------------
;; Language features
;; ---------------------------------------------------------------------

(define (hover-result uri text line ch)
  (define off (pos->offset text line ch))
  (define-values (word wstart wend) (word-at text off))
  (cond
    [(not word) 'null]
    [else
     (define contents
       (cond
         [(hash-ref stdlib-by-name word #f)
          => (λ (s)
               (format "```scheme\n~a\n```\n\n~a\n\n*stdlib primitive, arity ~a*"
                       (prim-signature s) (prim-spec-doc s) (prim-spec-arity s)))]
         [(find-define text word)
          => (λ (d) (format "```scheme\n~a\n```\n\n*defined in this buffer, line ~a*"
                            (defn-head d) (add1 (defn-line d))))]
         [(hash-ref prelude-by-name word #f)
          => (λ (d) (format "```scheme\n~a\n```\n\n*prelude function (src/prelude.puf)*"
                            (defn-head d)))]
         [else #f]))
     (cond
       [contents
        (define-values (l0 c0) (offset->pos text wstart))
        (define-values (l1 c1) (offset->pos text wend))
        (hasheq 'contents (hasheq 'kind "markdown" 'value contents)
                'range (range-jsexpr l0 c0 l1 c1))]
       [else 'null])]))

;; CompletionItemKind: 3 = Function, 6 = Variable
(define (completion-result text)
  (define seen (mutable-set))
  (define items '())
  (define (add! label kind detail [doc #f])
    (unless (set-member? seen label)
      (set-add! seen label)
      (define base (hasheq 'label label 'kind kind 'detail detail))
      (set! items (cons (if doc (hash-set base 'documentation doc) base) items))))
  ;; buffer defines shadow prelude shadow stdlib
  (for ([d (buffer-defines text)])
    (add! (symbol->string (defn-name d)) (if (defn-fun? d) 3 6) (defn-head d)))
  (for ([d prelude-defines])
    (add! (symbol->string (defn-name d)) 3 (defn-head d) "prelude function (src/prelude.puf)"))
  (for ([s surface-prims])
    (add! (symbol->string (prim-spec-name s)) 3
          (format "~a — stdlib, arity ~a" (prim-signature s) (prim-spec-arity s))
          (prim-spec-doc s)))
  (reverse items))

(define (defn-location uri d)
  (hasheq 'uri uri
          'range (range-jsexpr (defn-line d) (defn-col d)
                               (defn-line d)
                               (+ (defn-col d) (string-length (defn-head d))))))

(define (definition-result uri text line ch)
  (define off (pos->offset text line ch))
  (define-values (word _s _e) (word-at text off))
  (define d (and word (find-define text word)))
  (if d (defn-location uri d) 'null))

;; SymbolKind: 12 = Function, 13 = Variable
(define (document-symbol-result uri text)
  (for/list ([d (buffer-defines text)])
    (hasheq 'name (symbol->string (defn-name d))
            'kind (if (defn-fun? d) 12 13)
            'location (defn-location uri d))))

;; ---------------------------------------------------------------------
;; Dispatch
;; ---------------------------------------------------------------------

(define server-capabilities
  (hasheq 'textDocumentSync 1 ;; TextDocumentSyncKind.Full
          'hoverProvider #t
          'completionProvider (hasheq 'triggerCharacters (list "("))
          'definitionProvider #t
          'documentSymbolProvider #t))

(define (params-of msg) (hash-ref msg 'params (hasheq)))
(define (uri-of params) (hash-ref (hash-ref params 'textDocument (hasheq)) 'uri ""))
(define (position-of params)
  (define p (hash-ref params 'position (hasheq)))
  (values (hash-ref p 'line 0) (hash-ref p 'character 0)))
(define (doc-text params) (hash-ref documents (uri-of params) #f))

(define (handle-message msg)
  (define method (hash-ref msg 'method #f))
  (define id (hash-ref msg 'id #f))
  (define params (params-of msg))
  (with-handlers ([exn:fail?
                   (λ (e)
                     (eprintf "puffin-lsp: error handling ~a: ~a\n" method (exn-message e))
                     (when id (respond-error id -32603 (exn-message e))))])
    (match method
      ["initialize"
       (respond id (hasheq 'capabilities server-capabilities
                           'serverInfo (hasheq 'name "puffin-lsp" 'version "0.1")))]
      ["initialized" (void)]
      ["shutdown" (respond id 'null)]
      ["exit" (exit 0)]
      ["textDocument/didOpen"
       (define doc (hash-ref params 'textDocument (hasheq)))
       (define uri (hash-ref doc 'uri ""))
       (define text (hash-ref doc 'text ""))
       (hash-set! documents uri text)
       (publish-diagnostics! uri text)]
      ["textDocument/didChange"
       (define uri (uri-of params))
       (define changes (hash-ref params 'contentChanges '()))
       ;; full sync: the last change carries the whole document
       (unless (null? changes)
         (define text (hash-ref (last changes) 'text ""))
         (hash-set! documents uri text)
         (publish-diagnostics! uri text))]
      ["textDocument/didClose"
       (define uri (uri-of params))
       (hash-remove! documents uri)
       (notify "textDocument/publishDiagnostics"
               (hasheq 'uri uri 'diagnostics '()))]
      ["textDocument/hover"
       (define text (doc-text params))
       (define-values (line ch) (position-of params))
       (respond id (if text (hover-result (uri-of params) text line ch) 'null))]
      ["textDocument/completion"
       (define text (doc-text params))
       (respond id (if text (completion-result text) '()))]
      ["textDocument/definition"
       (define text (doc-text params))
       (define-values (line ch) (position-of params))
       (respond id (if text (definition-result (uri-of params) text line ch) 'null))]
      ["textDocument/documentSymbol"
       (define text (doc-text params))
       (respond id (if text (document-symbol-result (uri-of params) text) '()))]
      [_
       ;; unknown request -> MethodNotFound; unknown notification -> ignore
       (when id (respond-error id -32601 (format "method not found: ~a" method)))])))

(module+ main
  (let loop ()
    (define msg (read-lsp-message))
    (cond
      [(eof-object? msg) (exit 0)]
      [(eq? msg 'bad-json) (loop)]
      [else (handle-message msg) (loop)])))
