// lib/predicates.c -- type predicates over the tag scheme.
//
// Manifest entries: fixnum? boolean? symbol? void? procedure?
// (pair?/null?/vector?/string?/hash?/set? live with their types.)

#include "../puffin.h"

pf pf_fixnum_huh(pf v)    { return PF_BOOL((v & PF_TAG_MASK) == PF_TAG_FIXNUM); }
pf pf_boolean_huh(pf v)   { return PF_BOOL(v == PF_TRUE || v == PF_FALSE); }
pf pf_symbol_huh(pf v)    { return PF_BOOL((v & PF_TAG_MASK) == PF_TAG_SYMBOL); }
pf pf_void_huh(pf v)      { return PF_BOOL(v == PF_VOID); }
pf pf_procedure_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_CLOSURE)); }
