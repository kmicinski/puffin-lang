// lib/stdlib_init.c -- the one place that lists stdlib modules.
//
// Adding a module: implement lib/<module>.c with a
// pf_lib_<module>_init hook, add one line here, add its manifest
// entries to stdlib.rkt, add it to the Makefile's LIB_SRCS. The
// core (core.c) never changes.

void pf_lib_pairs_init(void);
void pf_lib_vectors_init(void);
void pf_lib_strings_init(void);
void pf_lib_hashes_init(void);
void pf_lib_sets_init(void);
void pf_lib_hamt_init(void);
void pf_lib_adt_init(void);
void pf_lib_io_init(void);

void pf_stdlib_init(void) {
  pf_lib_pairs_init();
  pf_lib_vectors_init();
  pf_lib_strings_init();
  pf_lib_hashes_init();
  pf_lib_sets_init();
  pf_lib_hamt_init();
  pf_lib_adt_init();
  pf_lib_io_init();
}
