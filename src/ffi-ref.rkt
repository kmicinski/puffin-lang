#lang racket

;; Puffin -- ffi-ref.rkt: the FFI's reference implementations
;; (docs/FFI.md §8.3), backing the manifest entries #%ffi-register /
;; #%ffi-call0..6 for the reference interpreter route. Loaded LAZILY
;; by stdlib.rkt (dynamic-require on the first registration) so that
;; programs without foreign declarations never load it -- and so this
;; file is EXEMPT from the module-load gensym budget (system.rkt):
;; macros here are free.
;;
;; Every check re-implements lib/foreign.c's semantics with the SAME
;; message bytes: the golden runner holds the interpreter and the
;; compiled routes equal. ffi/unsafe supplies dlopen/dlsym
;; (ffi-lib/get-ffi-obj) and the integer-class generic call shape
;; ((_cprocedure (list _int64 ...) _int64), docs/FFI.md §8.2).

(require "stdlib.rkt")   ;; render-value, ffi-handle-ops

;; the handle struct proper (stdlib.rkt's foreign-handle? etc. proxy
;; through the ops vector installed below)
(struct fhandle (ptr brand shown [closed? #:mutable]))
(set-box! ffi-handle-ops
          (vector fhandle?
                  (λ (v out)
                    (if (fhandle-closed? v)
                        (display (format "#<~a closed>" (fhandle-shown v)) out)
                        (display (format "#<~a 0x~x>" (fhandle-shown v) (fhandle-ptr v)) out)))
                  fhandle-brand))

(provide ffi-register-impl ffi-call-impl)

(define ffi-u-cache (make-hasheq))
(define (ffi-u name)
  (or (hash-ref ffi-u-cache name #f)
      (let ([v (dynamic-require 'ffi/unsafe name)])
        (hash-set! ffi-u-cache name v)
        v)))

;; the import registry: index -> (vector fn gift nargs ret args name pos)
(define ffi-imports (make-hash))
(define ffi-lib-cache (make-hash))    ;; rpath -> lib

(define (ffi-fatal msg)
  (flush-output)
  (fprintf (current-error-port) "puffin runtime error: ~a\n" msg)
  (exit 255))

;; the §5.2 blame grammar, shared by every failure below
(define (ffi-blame-site name pos argk)
  (if (> argk 0)
      (format "foreign ~a's argument ~a~a" name argk pos)
      (format "foreign ~a's result~a" name pos)))
(define (ffi-blame-cast name pos what got argk)
  (ffi-fatal (format "cast: expected ~a, got ~a (blame: ~a)"
                     what (render-value got) (ffi-blame-site name pos argk))))
(define (ffi-blame-msg name pos msg argk)
  (ffi-fatal (format "foreign ~a: ~a (blame: ~a)"
                     name msg (ffi-blame-site name pos argk))))

(define (ffi-open-lib rpath spath)
  (or (hash-ref ffi-lib-cache rpath #f)
      (let ([lib (with-handlers
                     ([(λ (_) #t)
                       (λ (e)
                         (flush-output)
                         (fprintf (current-error-port)
                                  "puffin runtime error: foreign library ~a: cannot load\n" spath)
                         (when (exn? e)
                           (fprintf (current-error-port) "  (dlerror: ~a)\n" (exn-message e)))
                         (exit 255))])
                   ((ffi-u 'ffi-lib) rpath))])
        (hash-set! ffi-lib-cache rpath lib)
        lib)))

(define (ffi-resolve lib cname iname spath n-args)
  ;; every import is called through the integer-class generic shape
  ;; (docs/FFI.md §8.2): n int64 arguments, an int64 result
  (define type ((ffi-u '_cprocedure) (make-list n-args (ffi-u '_int64)) (ffi-u '_int64)))
  (with-handlers
      ([(λ (_) #t)
        (λ (_)
          (ffi-fatal (format "foreign ~a: symbol ~a not found in ~a" iname cname spath)))])
    ((ffi-u 'get-ffi-obj) cname lib type)))

;; C-string helpers over raw addresses (the reference-side analogue of
;; the borrow/copy discipline; latin-1 keeps Puffin's byte strings
;; byte-faithful in both directions)
(define (ffi-read-cstring addr)
  (define ptr ((ffi-u 'cast) addr (ffi-u '_intptr) (ffi-u '_pointer)))
  (define bs
    (let loop ([i 0] [acc '()])
      (define b ((ffi-u 'ptr-ref) ptr (ffi-u '_ubyte) i))
      (if (zero? b) (list->bytes (reverse acc)) (loop (add1 i) (cons b acc)))))
  (bytes->string/latin-1 bs))
(define (ffi-alloc-cstring s)
  (define bs (string->bytes/latin-1 s))
  (define n (bytes-length bs))
  (define p ((ffi-u 'malloc) (add1 n) 'raw))
  (for ([b bs] [i (in-naturals)]) ((ffi-u 'ptr-set!) p (ffi-u '_ubyte) i b))
  ((ffi-u 'ptr-set!) p (ffi-u '_ubyte) n 0)
  p)
(define (ffi-ptr->int p) ((ffi-u 'cast) p (ffi-u '_pointer) (ffi-u '_intptr)))

;; (#%ffi-register rpath spath cname desc) -> import index
;; desc = (name-str pos-str ret arg ...) -- see lib/foreign.c
(define (ffi-register-impl rpath spath cname desc)
  (match-define (list* name pos ret args) desc)
  (define gift-sym
    (match ret [`(,(or 'str-gift 'nullable-str-gift) ,g) g] [_ #f]))
  (define lib (ffi-open-lib rpath spath))
  (define fn (ffi-resolve lib cname name spath (length args)))
  (define gift (and gift-sym (ffi-resolve lib gift-sym name spath 1)))
  ;; a #:consumes brand joins the leak detector's watch set
  (for ([a args])
    (match a
      [`(handle-consume ,brand ,_) (set-add! ffi-closeable brand)]
      [_ (void)]))
  (define idx (hash-count ffi-imports))
  (hash-set! ffi-imports idx (vector fn gift (length args) ret args name pos))
  idx)

(define (ffi-width-range w)
  (case w
    [(i8)  (cons -128 127)]
    [(i16) (cons -32768 32767)]
    [(i32) (cons -2147483648 2147483647)]
    [(u8)  (cons 0 255)]
    [(u16) (cons 0 65535)]
    [(u32) (cons 0 4294967295)]
    [else #f]))
(define (ffi-width-name w)
  (case w [(i8) "I8"] [(i16) "I16"] [(i32) "I32"] [(i64) "I64"]
          [(u8) "U8"] [(u16) "U16"] [(u32) "U32"] [(u64) "U64"] [else "Int"]))

;; outbound: check v against the spec, produce the raw int64 (plus a
;; cleanup thunk for allocated C strings)
(define (ffi-marshal-out name pos spec v argk cleanups)
  (match spec
    ['int
     (unless (exact-integer? v) (ffi-blame-cast name pos "Int" v argk))
     v]
    [(? (λ (s) (memq s '(i8 i16 i32 i64 u8 u16 u32 u64))) w)
     (unless (exact-integer? v) (ffi-blame-cast name pos "Int" v argk))
     (define r (ffi-width-range w))
     (cond
       [(not r) (if (and (eq? w 'u64) (negative? v))
                    (ffi-blame-cast name pos "U64" v argk)
                    v)]
       [(and (>= v (car r)) (<= v (cdr r))) v]
       [else (ffi-blame-cast name pos (ffi-width-name w) v argk)])]
    ['bool
     (unless (boolean? v) (ffi-blame-cast name pos "Bool" v argk))
     (if v 1 0)]
    ['str
     (unless (string? v) (ffi-blame-cast name pos "Str" v argk))
     (when (for/or ([ch v]) (char=? ch #\nul))
       (ffi-blame-msg name pos (format "argument ~a contains an embedded NUL" argk) argk))
     (define p (ffi-alloc-cstring v))
     (set-box! cleanups (cons (λ () ((ffi-u 'free) p)) (unbox cleanups)))
     (ffi-ptr->int p)]
    [`(,(or 'handle 'handle-consume) ,brand ,shown)
     (unless (and (fhandle? v) (eq? (fhandle-brand v) brand))
       (ffi-blame-cast name pos shown v argk))
     (when (fhandle-closed? v)
       (ffi-blame-msg name pos (format "~a handle is closed" shown) argk))
     (fhandle-ptr v)]))

;; inbound: construct the reference value per the result spec
(define (ffi-marshal-in name pos spec gift r)
  (define (check-61 x shown-x)
    (define top (arithmetic-shift x -60))
    (unless (or (= top 0) (= top -1))
      (ffi-fatal (format "cast: expected Int (61-bit), got ~a (blame: foreign ~a's result~a)"
                         shown-x name pos)))
    x)
  (define (mask-signed x bits)
    (define m (- (arithmetic-shift 1 bits) 1))
    (define u (bitwise-and x m))
    (if (bitwise-bit-set? u (sub1 bits)) (- u (arithmetic-shift 1 bits)) u))
  (match spec
    ['void (void)]
    [(or 'int 'i64) (check-61 r r)]
    ['i8  (mask-signed r 8)]
    ['i16 (mask-signed r 16)]
    ['i32 (mask-signed r 32)]
    ['u8  (bitwise-and r #xFF)]
    ['u16 (bitwise-and r #xFFFF)]
    ['u32 (bitwise-and r #xFFFFFFFF)]
    ['u64
     (define u (bitwise-and r #xFFFFFFFFFFFFFFFF))
     (unless (<= u (sub1 (arithmetic-shift 1 60)))
       (ffi-fatal (format "cast: expected Int (61-bit), got ~a (blame: foreign ~a's result~a)"
                          u name pos)))
     u]
    ['bool (not (zero? (bitwise-and r #xFFFFFFFF)))]
    [(or 'str `(str-gift ,_))
     (when (zero? r) (ffi-blame-msg name pos "result is NULL" 0))
     (define s (ffi-read-cstring r))
     (when gift (gift r))
     s]
    [(or `(nullable str) `(nullable-str-gift ,_))
     (if (zero? r)
         #f
         (let ([s (ffi-read-cstring r)]) (when gift (gift r)) s))]
    [`(handle ,brand ,shown)
     (when (zero? r) (ffi-blame-msg name pos "result is NULL" 0))
     (define h (fhandle r brand shown #f))
     (ffi-track! h)
     h]
    [`(nullable-handle ,brand ,shown)
     (if (zero? r)
         #f
         (let ([h (fhandle r brand shown #f)]) (ffi-track! h) h))]))

;; the finalizer BACKSTOP, reference side (docs/FFI.md §6.2, §13 Q4):
;; mirror lib/foreign.c's warn-to-stderr leak detector -- at process
;; exit, handles that are still open and whose brand participates in
;; a close discipline (#:consumes) are reported. A plumber flush
;; callback is the exit-time hook.
(define ffi-tracked '())          ;; newest first
(define ffi-closeable (mutable-seteq))
(define ffi-report-installed #f)
(define (ffi-report-leaks)
  (define open
    (reverse (filter (λ (h) (and (not (fhandle-closed? h))
                                 (set-member? ffi-closeable (fhandle-brand h))))
                     ffi-tracked)))
  (define leaked (length open))
  (when (> leaked 0)
    (flush-output)
    (fprintf (current-error-port) "puffin ffi warning: ~a foreign handle~a left open at exit"
             leaked (if (= leaked 1) "" "s"))
    (for ([h open] [i (in-naturals)] #:when (< i 8))
      (fprintf (current-error-port) "~a #<~a>" (if (zero? i) ":" ",") (fhandle-shown h)))
    (when (> leaked 8) (fprintf (current-error-port) ", ..."))
    (fprintf (current-error-port) "\n")))
(define (ffi-track! h)
  (unless ffi-report-installed
    (plumber-add-flush! (current-plumber) (λ (_) (ffi-report-leaks)))
    (set! ffi-report-installed #t))
  (when (< (length ffi-tracked) 4096)
    (set! ffi-tracked (cons h ffi-tracked))))

(define (ffi-call-impl idx argv)
  (match-define (vector fn gift nargs ret args name pos) (hash-ref ffi-imports idx))
  (unless (= (length argv) nargs) (ffi-fatal "ffi: call arity does not match the declaration"))
  (define cleanups (box '()))
  (define raw
    (for/list ([spec args] [v argv] [k (in-naturals 1)])
      (ffi-marshal-out name pos spec v k cleanups)))
  (define r (apply fn raw))
  ;; construct the result BEFORE freeing the outbound C-string
  ;; buffers: a callee may legally return a pointer into a borrowed
  ;; argument (strstr-style), and the borrow lasts through the copy
  (define out (ffi-marshal-in name pos ret gift r))
  (for ([c (unbox cleanups)]) (c))
  ;; #:consumes closes AFTER the call (null-on-close, docs/FFI.md §6.2)
  (for ([spec args] [v argv])
    (match spec
      [`(handle-consume ,_ ,_) (set-fhandle-closed?! v #t)]
      [_ (void)]))
  out)

