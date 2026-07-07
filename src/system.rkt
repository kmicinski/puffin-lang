#lang racket

;; Puffin -- system.rkt
;;
;; This file abstracts common flags and abstracts around ABI-level
;; and target-level details. It is the Puffin descendant of the
;; class projects' system.rkt: same role, extended with (a) the
;; tagged-value representation, (b) a *target* parameter which lets
;; the rest of the compiler stay target-agnostic, and (c) the
;; register sets used by the live-range register allocator.

(provide (all-defined-out))
(require racket/system)
(require racket/runtime-path)

;; Locate runtime.c next to this file, regardless of the working
;; directory the compiler was invoked from.
(define-runtime-path here-dir ".")

(define asm-file (make-parameter "./output.s"))
(define object-file (make-parameter "./output.o"))
(define executable-file (make-parameter "./output"))
(define runtime-file (make-parameter (build-path here-dir "runtime.c")))
(define runtime-object-file (make-parameter "./runtime.o"))
(define run-test-mode (make-parameter #f))
(define start-pass (make-parameter "desugar")) ;; synced with main.rkt
(define end-pass (make-parameter "render-asm"))  ;; synced with main.rkt
(define write-stdout-mode (make-parameter #t))
(define verbose-mode (make-parameter #t))
(define intermediate-ir (make-parameter #f))
(define test-mode (make-parameter "native"))
(define input-file (make-parameter #f))

;; Emit tag/bounds checks on user-facing pair/vector operations. Turn
;; off for benchmarking; leave on for day-to-day sanity.
(define safe-mode (make-parameter #t))

(define (yesno b?) (if b? "YES" "NO")) ;; pretty terminal output

(define (host-os)      (system-type 'os))       ; 'macosx or 'unix (Linux/BSD)
(define (host-arch)    (system-type 'machine))  ; x86_64, aarch64/arm64, ...

;; ---------------------------------------------------------------------
;; Targets: 'x86-64 or 'arm64. The default is the host architecture,
;; so plain builds Just Work on both kinds of machines. On an ARM
;; mac, the x86-64 target still runs (via Rosetta)--we use that to
;; check the two backends agree.
;; ---------------------------------------------------------------------

(define (default-target)
  (if (regexp-match? #rx"(aarch64|arm64)" (format "~a" (host-arch)))
      'arm64
      'x86-64))

(define target (make-parameter (default-target)))

;; optimization level: 0 = none, 1 = contraction/inlining + safe
;; open-coded prims (cp0-class budgets), 2 = + AAM flow analysis and
;; its clients (see docs/OPTIMIZER.md)
(define optimize-level (make-parameter 1))

(define (entry-symbol) 'main)
(define (conclusion-block-name)   'conclusion)

;; ---------------------------------------------------------------------
;; Tagged value representation (shared contract between the compiler,
;; the interpreters, and runtime.c -- keep all three in sync!)
;;
;;   fixnum:      n << 3          (low bits 000)
;;   heap ptr:    ptr | 1         (low bits 001; kind lives in the header)
;;   immediates:  low bits 010    (payload in bits 3+)
;;   symbol:      id << 3 | 3     (low bits 011; interned at startup)
;;
;; Because fixnums are n<<3, tagged +, -, eq?, and < all work
;; directly on tagged values, and a tagged index *is* a byte offset
;; into a vector's elements. This is why the instruction selector
;; barely changes relative to the untagged class compiler.
;; ---------------------------------------------------------------------

(define (tag-fixnum n) (arithmetic-shift n 3))
(define (untag-fixnum v) (arithmetic-shift v -3))
(define false-value  2)  ;; (0 << 3) | 2
(define true-value  10)  ;; (1 << 3) | 2
(define void-value  18)  ;; (2 << 3) | 2
(define nil-value   26)  ;; (3 << 3) | 2
(define (tag-immediate v)
  (match v
    [#f false-value]
    [#t true-value]
    ['(void) void-value]
    ['(nil)  nil-value]))
(define (tag-symbol id) (bitwise-ior (arithmetic-shift id 3) 3))

;; Heap object kinds (the low byte of every heap object's header
;; word; the object's length lives in the bits above it).
(define heap-kind/vector  1)
(define heap-kind/pair    2)
(define heap-kind/string  3)
(define heap-kind/hash    4)
(define heap-kind/set     5)

;; Turn a string into its "runtime symbol" version: on OSX, names need
;; to be prefixed with _, but not on Linux.
(define (rt-sym s)
  ;; assembler labels allow [A-Za-z0-9_$]; scheme identifiers allow
  ;; much more, so encode the usual suspects readably and anything
  ;; else by code point
  (define (sanitize sym)
    (string->symbol
     (apply string-append
            (map (λ (ch)
                   (cond [(or (char-alphabetic? ch) (char-numeric? ch) (char=? ch #\_)) (string ch)]
                         [(char=? ch #\-) "_"]
                         [(char=? ch #\?) "_huh"]
                         [(char=? ch #\!) "_bang"]
                         [(char=? ch #\>) "_to"]
                         [(char=? ch #\<) "_lt"]
                         [(char=? ch #\=) "_eq"]
                         [(char=? ch #\*) "_star"]
                         [(char=? ch #\/) "_slash"]
                         [(char=? ch #\+) "_plus"]
                         [else (format "_u~x" (char->integer ch))]))
                 (string->list (symbol->string sym))))))
  (if (equal? (host-os) 'macosx)
      (macify (sanitize s))
      (linuxify (sanitize s))))

;; The runtime (runtime.c) entry points the generated code may call.
(define (runtime-functions)
  '(pf_init pf_read_int pf_print_result pf_println pf_display pf_newline
    pf_make_vector pf_vector_length
    pf_cons pf_car pf_cdr pf_pair_huh pf_null_huh
    pf_make_hash pf_hash_set pf_hash_ref pf_hash_ref_default pf_hash_has pf_hash_count pf_hash_keys pf_hash_remove
    pf_make_set pf_set_add pf_set_member pf_set_count pf_set_to_list pf_set_remove
    pf_symbol_to_string pf_string_length pf_string_append pf_string_equal_huh pf_string_const
    pf_die_oob pf_die_kind pf_die_arith pf_equal_huh))

;; have to include these extern definitions at the top of the file
(define (runtime-function-externs)
  (apply string-append (map (λ (x) (format ".extern ~a\n" (symbol->string (rt-sym x)))) (runtime-functions))))

(define (macify s)
  (define str (symbol->string s))
  (if (and (positive? (string-length str))
           (char=? (string-ref str 0) #\_))
      s
      (string->symbol (string-append "_" str))))

;; Convert a Mac symbol to Linux
(define (linuxify s)
  (define str (symbol->string s))
  (cond [(and (positive? (string-length str))
              (char=? (string-ref str 0) #\_))
         (string->symbol (substring str 1))]
        [else s]))

(define (execute-get-output cmd)
  (define args (string-split cmd))
  ;; Start subprocess with pipes for stdout+stderr
  (displayln cmd)
  (define-values (sp out in err)
    (apply subprocess #f #f #f (car args) (cdr args)))
  (subprocess-wait sp)
  (define out-str (if out (port->string out) ""))
  (define err-str (if err (port->string err) ""))
  (when out (close-input-port out))
  (when in  (close-output-port in))
  (when err (close-input-port err))
  (string-append out-str err-str))

;; Get a thunk's output alongside its stdout
(define (run/capture thunk)
  (define out (open-output-string))
  (define err (open-output-string))
  (define v (parameterize ([current-output-port out] [current-error-port err]) (thunk)))
  (cons v (string-append (get-output-string out) (if (equal? (get-output-string err) "")
                                                     ""
                                                     (format " stderr: ~a" (get-output-string err))))))

;; ---------------------------------------------------------------------
;; Per-target register conventions.
;;
;; The middle-end and the register allocator only ever ask these
;; questions; everything else about the ISA lives in the backend
;; (backend-x86.rkt / backend-arm64.rkt).
;; ---------------------------------------------------------------------

(define (argument-registers-list)
  (match (target)
    ['x86-64 '(rdi rsi rdx rcx r8 r9)]
    ['arm64  '(x0 x1 x2 x3 x4 x5)]))  ;; ARM has x0-x7; we use six to keep arity limiting identical

;; Registers the allocator may hand out. We restrict ourselves to
;; callee-saved registers: values in them survive calls, so live
;; ranges that cross calls (very common in Puffin code) need no
;; special treatment. Simple, and captures most of the win.
(define (allocatable-registers-list)
  (match (target)
    ['x86-64 '(rbx r12 r13 r14 r15)]
    ['arm64  '(x19 x20 x21 x22 x23 x24 x25 x26)]))

;; Scratch registers each backend may clobber freely inside a single
;; IR statement (never allocated, never live across statements).
(define (scratch-registers-list)
  (match (target)
    ['x86-64 '(rax r10 r11)]
    ['arm64  '(x9 x10 x11)]))

(define (frame-pointer-register)
  (match (target) ['x86-64 'rbp] ['arm64 'x29]))

;; Bytes the prologue's callee-saved save area occupies for n saved
;; registers: x86 pushes 8 bytes each; arm64 stores pairs (stp),
;; 16-byte aligned. regalloc places spill slots below this area.
(define (callee-save-area-bytes n)
  (match (target)
    ['x86-64 (* 8 n)]
    ['arm64  (* 16 (ceiling (/ n 2)))]))
