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

// ---- bootstrap additions (a compiler needs its bit twiddling) ------

static void expect_fix2(pf a, pf b) {
  if (((a | b) & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_arith();
}

// tagged fixnums have low bits 000, so AND and OR work directly
pf pf_bitwise_and(pf a, pf b) { expect_fix2(a, b); return a & b; }
pf pf_bitwise_ior(pf a, pf b) { expect_fix2(a, b); return a | b; }
pf pf_bitwise_xor(pf a, pf b) { expect_fix2(a, b); return a ^ b; }

pf pf_arith_shift(pf a, pf b) {
  expect_fix2(a, b);
  int64_t n = PF_UNFIX(a), k = PF_UNFIX(b);
  if (k >= 0) return PF_FIX(n << k);
  return PF_FIX(n >> (-k));
}

// (modulo a b): sign follows the divisor, as in Racket.
pf pf_modulo(pf a, pf b) {
  expect_fix2(a, b);
  if (b == 0) pf_fatal("modulo: division by zero");
  int64_t x = PF_UNFIX(a), y = PF_UNFIX(b);
  int64_t r = x % y;
  if (r != 0 && ((r < 0) != (y < 0))) r += y;
  return PF_FIX(r);
}
