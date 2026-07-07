// lib/io.c -- files, argv, and subprocesses: what a self-contained
// compiler driver needs (puffincc reads its input modules, writes
// assembly, and shells out to the system assembler/linker).
//
// Manifest entries: read-file write-file file-exists?
//                   command-line-args system

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../puffin.h"

extern pf pf_string_from_bytes(const char *bytes, int64_t n); // lib/strings.c
extern pf pf_cons(pf, pf);                                    // lib/pairs.c

// argv, captured before the generated main runs. Apple's dyld and
// glibc both pass (argc, argv, envp) to constructor functions, so no
// codegen cooperation is needed.
static int pf_saved_argc = 0;
static char **pf_saved_argv = NULL;

__attribute__((constructor)) static void pf_capture_args(int argc, char **argv) {
  pf_saved_argc = argc;
  pf_saved_argv = argv;
}

static const char *cstr_of(pf v) {
  pf_expect_kind(v, PF_KIND_STRING);
  return (const char *)(pf_heap_ptr(v) + 1); // NUL-terminated by layout
}

// (read-file path): the file's bytes as a string; errors if unreadable
pf pf_read_file(pf path) {
  const char *p = cstr_of(path);
  FILE *f = fopen(p, "rb");
  if (!f) {
    fprintf(stderr, "error: read-file: cannot open %s\n", p);
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc(n > 0 ? (size_t)n : 1);
  if (!buf) pf_fatal("read-file: out of memory");
  if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) {
    fprintf(stderr, "error: read-file: short read on %s\n", p);
    exit(1);
  }
  fclose(f);
  pf s = pf_string_from_bytes(buf, (int64_t)n);
  free(buf);
  return s;
}

// (write-file path str): (re)write the file with the string's bytes
pf pf_write_file(pf path, pf contents) {
  const char *p = cstr_of(path);
  pf_expect_kind(contents, PF_KIND_STRING);
  FILE *f = fopen(p, "wb");
  if (!f) {
    fprintf(stderr, "error: write-file: cannot open %s\n", p);
    exit(1);
  }
  int64_t n = pf_len_of(contents);
  if (n > 0 && fwrite(pf_heap_ptr(contents) + 1, 1, (size_t)n, f) != (size_t)n) {
    fprintf(stderr, "error: write-file: short write on %s\n", p);
    exit(1);
  }
  fclose(f);
  return PF_VOID;
}

pf pf_file_exists_huh(pf path) {
  return PF_BOOL(access(cstr_of(path), R_OK) == 0);
}

// (command-line-args): argv[1..] as a list of strings
pf pf_command_line_args(void) {
  pf args = PF_NIL;
  for (int i = pf_saved_argc - 1; i >= 1; i--)
    args = pf_cons(pf_string_from_bytes(pf_saved_argv[i], (int64_t)strlen(pf_saved_argv[i])), args);
  return args;
}

// (system cmd): run a shell command, return its exit code
pf pf_system(pf cmd) {
  int rc = system(cstr_of(cmd));
  if (rc == -1) pf_fatal("system: fork failed");
  return PF_FIX((int64_t)(rc >> 8) & 0xFF);
}

void pf_lib_io_init(void) {}
