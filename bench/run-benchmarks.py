#!/usr/bin/env python3
"""Puffin vs Racket benchmark runner.

Paired programs (same algorithm both sides) in bench/programs/.
Routes: puffin-arm64 (native), puffin-x86 (Rosetta), racket (Chez,
bytecode pre-compiled via raco make). N runs, median wall time,
min/max, max RSS. Also compile-time benchmarks including puffincc's
self-compile. Emits bench/results.json.

Honesty notes baked into methodology (also see report):
 - wall clock of the whole process, including startup; racket's
   startup baseline is measured separately and reported.
 - .rkt files are pre-compiled with `raco make` (Racket's best case).
 - identical algorithms: Racket's built-in sort is NOT used against
   Puffin's prelude sort; both sides run the same merge sort, etc.
"""
import json, subprocess, statistics, time, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "bench")
PROGS = os.path.join(BENCH, "programs")
BUILD = os.path.join(BENCH, "build")
os.makedirs(BUILD, exist_ok=True)
N = 5

BENCHMARKS = [
    ("fib", "fib(35), naive recursion", "calls"),
    ("tail-loop", "200M-iteration tail loop", "loops"),
    ("hamt", "1M persistent hash (HAMT) inserts + lookups", "data"),
    ("mut-hash", "5M mutable hash inserts + lookups", "data"),
    ("lists", "3M-element list build/reverse/map/fold", "data"),
    ("sort", "merge sort of 1M pseudorandom ints", "data"),
    ("vectors", "50M-slot vector fill + sum", "data"),
    ("strings", "quadratic string-append builder (60k)", "data"),
    ("lc-interp", "eval/apply interpreter running Z-fib(25)", "meta"),
    # PL-course workloads (scaled from the pl-* test suite)
    ("pl-rbtree", "red-black tree: 100k match-based inserts", "pl"),
    ("pl-nqueens", "n-queens: count solutions, n=11", "pl"),
    ("pl-regex", "NFA simulation over 250k symbols", "pl"),
    ("pl-symdiff", "6th symbolic derivative + simplification, 300 rounds", "pl"),
    ("pl-dpll", "DPLL SAT: pigeonhole PHP(7,6) unsat", "pl"),
]

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

def timed_run(cmd):
    """(wall_seconds, max_rss_bytes, stdout) for one run of cmd (list)."""
    t0 = time.monotonic()
    p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True)
    wall = time.monotonic() - t0
    if p.returncode != 0:
        raise RuntimeError(f"{cmd}: rc={p.returncode} {p.stderr[:300]}")
    rss = 0
    for line in p.stderr.splitlines():
        if "maximum resident set size" in line:
            rss = int(line.split()[0])
    return wall, rss, p.stdout.strip()

def bench_route(cmd, n=N):
    walls, rss, out = [], 0, None
    for _ in range(n):
        w, r, o = timed_run(cmd)
        walls.append(w)
        rss = max(rss, r)
        out = o
    return {
        "median": statistics.median(walls),
        "min": min(walls),
        "max": max(walls),
        "rss": rss,
        "output": out,
    }

def main():
    results = {"benchmarks": [], "meta": {}}

    # -- build all puffin binaries (hosted compiler), pre-compile rkt --
    print("building...", flush=True)
    for name, _, _ in BENCHMARKS:
        puf = os.path.join(PROGS, f"{name}.puf")
        for tgt, suffix in [("arm64", "arm"), ("x86-64", "x86")]:
            out = os.path.join(BUILD, f"{name}-{suffix}")
            r = sh(f"cd {ROOT} && bin/puffin -c -t {tgt} -o {out} {puf}")
            if not os.path.exists(out):
                print(r.stdout[-400:], r.stderr[-400:]); sys.exit(f"build failed: {name} {tgt}")
        sh(f"cd {PROGS} && raco make {name}.rkt")

    # racket startup baseline
    empty = os.path.join(BUILD, "empty.rkt")
    open(empty, "w").write("#lang racket\n")
    sh(f"raco make {empty}")
    results["meta"]["racket_startup"] = bench_route(["racket", empty])["median"]
    hello = os.path.join(BUILD, "hello-arm")
    open(os.path.join(BUILD, "hello.puf"), "w").write("(void)\n")
    sh(f"cd {ROOT} && bin/puffin -c -o {hello} {BUILD}/hello.puf")
    results["meta"]["puffin_startup"] = bench_route([hello])["median"]

    # -- run benchmarks --
    for name, desc, group in BENCHMARKS:
        print(f"running {name}...", flush=True)
        entry = {"name": name, "desc": desc, "group": group, "routes": {}}
        entry["routes"]["puffin-arm64"] = bench_route([os.path.join(BUILD, f"{name}-arm")])
        entry["routes"]["puffin-x86"] = bench_route([os.path.join(BUILD, f"{name}-x86")])
        entry["routes"]["racket"] = bench_route(["racket", os.path.join(PROGS, f"{name}.rkt")])
        outs = {r["output"] for r in entry["routes"].values()}
        entry["outputs_agree"] = len(outs) == 1
        if not entry["outputs_agree"]:
            print(f"  !! outputs differ: {outs}")
        results["benchmarks"].append(entry)

    # -- compile-time benchmarks --
    print("compile-time...", flush=True)
    fib = os.path.join(PROGS, "fib.puf")
    pccpuf = os.path.join(ROOT, "build", "puffincc.puf")
    ct = {}
    ct["hosted, fib (16 passes + clang)"] = bench_route(
        ["sh", "-c", f"cd {ROOT} && bin/puffin -c -o /tmp/bench-ct-fib {fib}"], n=3)["median"]
    ct["puffincc, fib (asm only)"] = bench_route(
        ["sh", "-c", f"cd {ROOT} && build/puffincc < {fib} > /tmp/bench-ct-fib.s"], n=3)["median"]
    ct["hosted, puffincc.puf (2972 lines)"] = bench_route(
        ["sh", "-c", f"cd {ROOT}/src && racket main.rkt -f -t arm64 {pccpuf} >/dev/null 2>&1"], n=2)["median"]
    ct["puffincc self-compile (stage 2)"] = bench_route(
        ["sh", "-c", f"cd {ROOT} && build/puffincc < {pccpuf} > /tmp/bench-ct-pcc.s"], n=2)["median"]
    results["compile_time"] = ct

    results["meta"]["n_runs"] = N
    results["meta"]["machine"] = sh("sysctl -n machdep.cpu.brand_string").stdout.strip()
    results["meta"]["racket_version"] = sh("racket --version").stdout.strip()
    json.dump(results, open(os.path.join(BENCH, "results.json"), "w"), indent=1)
    print("wrote bench/results.json")

if __name__ == "__main__":
    main()
