# FFI micro-benchmarks (docs/FFI.md §8.4)

Build the demo libraries first (`make -C tests/ffi-demo` and
`make -C tests/ffi-demo pfregex`), compile each `.puf` with
`bin/puffin -c` **from the repo root** (the foreign paths resolve
against it), and run from the repo root.

Measured 2026-07-13 (M4 Pro, arm64, -O1, best of 3):

| benchmark        | what it measures                                   | wall    | per call |
|------------------|----------------------------------------------------|---------|----------|
| `intrinsic`      | 10M iterations, open-coded `+`                     | 0.01 s  | ~1 ns    |
| `prim-call`      | 10M iterations, one manifest prim call (`quotient`)| 0.03 s  | ~3 ns    |
| `ffi-call`       | 10M iterations, one 2-arg foreign call (full       | 0.07 s  | ~7 ns    |
|                  | marshal: 2 Int checks, generic call, 61-bit retag) |         |          |
| `regex-rust`     | 20k lines, Rust `regex` crate via the FFI          | 0.17 s  |          |
| `regex-puffin`   | same workload, the pl-regex Thompson-NFA engine    | 0.73 s  |          |

The boundary premium is ~4 ns/call over a plain prim call — the
desc-interpretation loop plus the transient checks (docs/FFI.md §8.1
prices this in; FFI calls are boundary crossings, not inner loops).
Both regex benchmarks print the same count (26666): the borrowed
ecosystem is 4.3x faster than the in-language engine on this workload
while every crossing stays checked.
