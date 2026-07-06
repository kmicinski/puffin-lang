// lib/arith.c -- arithmetic helpers the compiler does not open-code.
//
// Manifest entries: quotient remainder
//
// (+, -, * and the comparisons are compiler intrinsics; division
// lives here so a zero divisor dies with a clean Puffin error
// instead of a SIGFPE.)

#include "../puffin.h"

pf pf_quotient(pf a, pf b) {
  if (((a | b) & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_arith();
  if (b == 0) pf_fatal("quotient: division by zero");
  return PF_FIX(PF_UNFIX(a) / PF_UNFIX(b));
}

pf pf_remainder(pf a, pf b) {
  if (((a | b) & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_arith();
  if (b == 0) pf_fatal("remainder: division by zero");
  return PF_FIX(PF_UNFIX(a) % PF_UNFIX(b));
}
