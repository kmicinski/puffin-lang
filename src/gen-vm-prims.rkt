#lang racket

;; Puffin -- gen-vm-prims.rkt: generate the VM's primitive table
;; (src/vm/vm-prims.inc) from the stdlib manifest.
;;
;; The bytecode backend's PRIM instruction carries a prim id that is
;; the primitive's *index in the stdlib.rkt manifest list*; this
;; generator emits the C table in the same order, so the two sides
;; agree by construction (the manifest-derivation discipline of
;; stdlib.rkt, extended with one more derived view). Regenerate and
;; commit whenever the manifest changes:
;;
;;   racket src/gen-vm-prims.rkt > src/vm/vm-prims.inc

(require "stdlib.rkt")

(printf "// GENERATED from the stdlib manifest -- do not edit.\n")
(printf "// (src/gen-vm-prims.rkt and tools/gen-vm-prims.puf emit this\n")
(printf "// identically; prim ids are manifest-list indices, computed from\n")
(printf "// the same list by the bytecode backends.)\n\n")

;; extern declarations with honest arity-derived prototypes
(for ([s stdlib-primitives])
  (define args (if (zero? (prim-spec-arity s))
                   "void"
                   (string-join (make-list (prim-spec-arity s) "pf") ", ")))
  (printf "extern pf ~a(~a);\n" (prim-spec-rt-sym s) args))

(printf "\nstatic const vm_prim vm_prims[] = {\n")
(for ([s stdlib-primitives])
  (printf "  {\"~a\", ~a, (vm_prim_fn)~a},\n"
          (prim-spec-name s) (prim-spec-arity s) (prim-spec-rt-sym s)))
(printf "};\n\n")
(printf "enum { VM_PRIM_COUNT = ~a };\n" (length stdlib-primitives))
