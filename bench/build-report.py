#!/usr/bin/env python3
"""Render bench/results.json as a static, self-contained HTML report
(bench/report.html). Charts are inline SVG; palette, mark specs, and
interaction follow the dataviz method (validated categorical slots
1-3; blue/red diverging poles with a gray midpoint; relief rule
satisfied via direct labels + the full table)."""
import json, math, os, html

BENCH = os.path.dirname(os.path.abspath(__file__))
R = json.load(open(os.path.join(BENCH, "results.json")))

ROUTES = ["puffin-arm64", "puffin-x86", "racket"]
ROUTE_LABEL = {"puffin-arm64": "Puffin arm64 (native)",
               "puffin-x86": "Puffin x86-64 (Rosetta)",
               "racket": "Racket 8.15 (Chez)"}
# categorical slots 1-3, light/dark (validated)
LIGHT = {"puffin-arm64": "#2a78d6", "puffin-x86": "#1baf7a", "racket": "#eda100"}
DARK  = {"puffin-arm64": "#3987e5", "puffin-x86": "#199e70", "racket": "#c98500"}

def fmt_s(v):
    return f"{v*1000:.0f} ms" if v < 1 else f"{v:.2f} s"

def fmt_mb(b):
    return f"{b/1048576:.0f} MB" if b >= 10*1048576 else f"{b/1048576:.1f} MB"

svg_id = 0
def bar_chart(title, subtitle, rows, unit="s", log=False, ratio_mode=False, link_names=True):
    """rows: list of (group-label, [(series-key, value, lo, hi, tip)])."""
    global svg_id
    svg_id += 1
    LEFT, RIGHT, BAR_H, GAP, GROUP_GAP, TOP = 210, 90, 16, 2, 14, 8
    n_series = len(rows[0][1])
    group_h = n_series * (BAR_H + GAP) + GROUP_GAP
    H = TOP + len(rows) * group_h + 30
    W = 860
    plot_w = W - LEFT - RIGHT
    vals = [max(v, hi) if hi is not None else v for _, bars in rows for (_, v, lo, hi, _) in bars]
    vmax = max(vals)
    if log:
        lmin = min(v for _, bars in rows for (_, v, _, _, _) in bars)
        lo_e = math.floor(math.log10(lmin))
        hi_e = math.ceil(math.log10(vmax))
        def X(v): return LEFT + plot_w * (math.log10(v) - lo_e) / (hi_e - lo_e)
        ticks = [10**e for e in range(lo_e, hi_e + 1)]
    elif ratio_mode:
        # symmetric log2 around 1.0
        m = max(abs(math.log2(v)) for _, bars in rows for (_, v, _, _, _) in bars)
        m = max(m, 1.2)
        def X(v): return LEFT + plot_w * (math.log2(v) + m) / (2 * m)
        ticks = [0.25, 0.5, 1, 2, 4]
        ticks = [t for t in ticks if abs(math.log2(t)) <= m]
    else:
        # ~5 ticks: snap vmax/5 to a nice step
        raw = vmax / 5
        mag = 10 ** math.floor(math.log10(raw))
        step = min((s for s in (1, 2, 2.5, 5, 10) if s * mag >= raw), default=10) * mag
        top = step * math.ceil(vmax / step)
        def X(v): return LEFT + plot_w * v / top
        ticks = [step * i for i in range(int(round(top / step)) + 1)]
    out = [f'<figure class="chart"><figcaption><strong>{html.escape(title)}</strong>'
           f'<span class="sub">{html.escape(subtitle)}</span></figcaption>']
    out.append(f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="{html.escape(title)}">')
    # recessive grid + tick labels
    for t in ticks:
        x = X(t) if not (not log and not ratio_mode and t == 0) else LEFT
        label = (f"{t:g}×" if ratio_mode else (fmt_s(t) if unit == "s" else f"{t:g} MB"))
        out.append(f'<line x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{H-26}" class="grid"/>')
        out.append(f'<text x="{x:.1f}" y="{H-12}" class="tick" text-anchor="middle">{label}</text>')
    if ratio_mode:
        x1 = X(1)
        out.append(f'<line x1="{x1:.1f}" y1="{TOP-2}" x2="{x1:.1f}" y2="{H-26}" class="baseline"/>')
    y = TOP
    x0 = X(ticks[0]) if (log or ratio_mode) else LEFT
    for glabel, bars in rows:
        gy = y
        for (key, v, lo, hi, tip) in bars:
            bx = X(v)
            if ratio_mode:
                # diverging: faster-than-racket = blue pole, slower = red pole
                col = 'var(--pole-fast)' if v < 1 else 'var(--pole-slow)'
                start = min(x0 if not ratio_mode else X(1), bx)
                width = abs(bx - (X(1) if ratio_mode else x0))
                rx = 4
                out.append(f'<rect x="{start:.1f}" y="{y}" width="{max(width,1):.1f}" height="{BAR_H}" rx="{rx}" '
                           f'fill="{col}" class="mark" data-tip="{html.escape(tip)}"/>')
            else:
                width = bx - x0
                out.append(f'<rect x="{x0:.1f}" y="{y}" width="{max(width,1):.1f}" height="{BAR_H}" rx="4" '
                           f'fill="var(--c-{key})" class="mark" data-tip="{html.escape(tip)}"/>')
            if lo is not None:
                out.append(f'<line x1="{X(lo):.1f}" y1="{y+BAR_H/2:.1f}" x2="{X(hi):.1f}" y2="{y+BAR_H/2:.1f}" class="whisker"/>')
            # direct value label (relief rule), placed clear of the whisker
            if ratio_mode:
                vtext = f"{v:.2f}×"
            elif unit == "s":
                vtext = fmt_s(v)
            else:
                vtext = f"{v:.1f} MB" if v < 10 else f"{v:.0f} MB"
            if ratio_mode and v < 1:
                out.append(f'<text x="{bx-6:.1f}" y="{y+BAR_H-4}" class="vlabel" text-anchor="end">{vtext}</text>')
            else:
                lx = max(bx, x0, X(hi) if hi is not None else 0) + 6
                out.append(f'<text x="{lx:.1f}" y="{y+BAR_H-4}" class="vlabel">{vtext}</text>')
            y += BAR_H + GAP
        cls, data = ("glabel src-link", f' data-prog="{html.escape(glabel)}"') if link_names else ("glabel", "")
        out.append(f'<text x="{LEFT-8}" y="{gy + (y-gy)/2 + 4 - GAP/2:.1f}" class="{cls}"{data} text-anchor="end">{html.escape(glabel)}</text>')
        y += GROUP_GAP
    out.append('</svg></figure>')
    return "\n".join(out)

# ---- assemble data ---------------------------------------------------

bench_rows, pl_rows, ratio_rows, rss_rows = [], [], [], []
geo, geo_pl = [], []
for b in R["benchmarks"]:
    rr = b["routes"]
    bars, rssbars = [], []
    for k in ROUTES:
        m = rr[k]
        bars.append((k, m["median"], m["min"], m["max"],
                     f"{ROUTE_LABEL[k]} — {b['desc']}: median {fmt_s(m['median'])} "
                     f"(min {fmt_s(m['min'])}, max {fmt_s(m['max'])}, {R['meta']['n_runs']} runs)"))
        rssbars.append((k, m["rss"]/1048576, None, None,
                        f"{ROUTE_LABEL[k]} — {b['desc']}: peak RSS {fmt_mb(m['rss'])}"))
    label = b["name"]
    (pl_rows if b["group"] == "pl" else bench_rows).append((label, bars))
    rss_rows.append((label, rssbars))
    ratio = rr["puffin-arm64"]["median"] / rr["racket"]["median"]
    (geo_pl if b["group"] == "pl" else geo).append(math.log(ratio))
    ratio_rows.append((label, [("ratio", ratio, None, None,
                       f"{b['desc']}: Puffin arm64 is {ratio:.2f}× Racket's wall time "
                       f"({'faster' if ratio < 1 else 'slower'})")]))
geomean = math.exp(sum(geo + geo_pl)/len(geo + geo_pl))
geomean_pl = math.exp(sum(geo_pl)/len(geo_pl)) if geo_pl else None
wins = sum(1 for _, bars in ratio_rows if bars[0][1] < 1)

ct_rows = []
for k, v in R["compile_time"].items():
    who = "puffincc" if k.startswith("puffincc") else "hosted"
    ct_rows.append((k, [(("puffin-arm64" if who == "puffincc" else "racket"), v, None, None,
                        f"{k}: {fmt_s(v)}")]))

table_rows = []
for b in R["benchmarks"]:
    rr = b["routes"]
    cells = "".join(
        f"<td>{fmt_s(rr[k]['median'])}<span class='mm'> [{fmt_s(rr[k]['min'])}–{fmt_s(rr[k]['max'])}]</span></td>"
        f"<td class='rss'>{fmt_mb(rr[k]['rss'])}</td>"
        for k in ROUTES)
    ratio = rr["puffin-arm64"]["median"] / rr["racket"]["median"]
    table_rows.append(f"<tr><th><span class='src-link' data-prog='{b['name']}'>{b['name']}</span></th>"
                      f"<td class='desc'>{html.escape(b['desc'])}</td>{cells}"
                      f"<td class='{ 'win' if ratio < 1 else 'lose'}'>{ratio:.2f}×</td></tr>")

# program sources for the in-page viewer (both sides of each pair)
def read_src(p):
    try: return open(os.path.join(BENCH, "programs", p)).read()
    except FileNotFoundError: return None
prog_sources = {}
for b in R["benchmarks"]:
    prog_sources[b["name"]] = {"desc": b["desc"],
                               "puffin": read_src(b["name"] + ".puf"),
                               "racket": read_src(b["name"] + ".rkt")}
pcc = os.path.join(os.path.dirname(BENCH), "build", "puffincc.puf")
if os.path.exists(pcc):
    prog_sources["puffincc"] = {"desc": "the self-hosted compiler (concatenated puffincc-src/)",
                                "puffin": open(pcc).read(), "racket": None}
sources_json = json.dumps(prog_sources)

meta = R["meta"]
page = f"""<!-- Puffin vs Racket benchmark report (generated by bench/build-report.py) -->
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Puffin vs Racket — benchmarks</title>
<style>
.viz-root {{
  --surface-1: #fcfcfb; --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #8a8880;
  --c-puffin-arm64: #2a78d6; --c-puffin-x86: #1baf7a; --c-racket: #eda100;
  --pole-fast: #2a78d6; --pole-slow: #e34948; --grid: #eceae5; --baseline: #b5b2a8;
  --card: #f6f5f2; --border: #e4e2dc; --win: #0ca30c; --lose: #d03b3b;
  font: 15px/1.55 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
  color: var(--text-primary); background: var(--surface-1);
  max-width: 980px; margin: 0 auto; padding: 28px 20px 80px;
}}
@media (prefers-color-scheme: dark) {{ .viz-root {{
  --surface-1: #1a1a19; --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #8a887d;
  --c-puffin-arm64: #3987e5; --c-puffin-x86: #199e70; --c-racket: #c98500;
  --pole-fast: #3987e5; --pole-slow: #e66767; --grid: #2b2b29; --baseline: #55534c;
  --card: #232322; --border: #34342f; --win: #35c235; --lose: #e66767;
}} }}
h1 {{ font-size: 26px; margin: 0 0 4px; }}
h2 {{ font-size: 19px; margin: 40px 0 6px; }}
.lede, .sub, .note {{ color: var(--text-secondary); }}
.note {{ font-size: 13px; }}
.tiles {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; margin: 22px 0; }}
.tile {{ background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; }}
.tile .n {{ font-size: 24px; font-weight: 650; letter-spacing: -0.5px; }}
.tile .l {{ font-size: 12.5px; color: var(--text-secondary); }}
.legend {{ display: flex; gap: 18px; margin: 10px 0 2px; font-size: 13.5px; color: var(--text-secondary); flex-wrap: wrap; }}
.legend span::before {{ content: ""; display: inline-block; width: 11px; height: 11px; border-radius: 3px; margin-right: 6px; vertical-align: -1px; background: var(--sw); }}
figure.chart {{ margin: 18px 0 8px; }}
figcaption {{ margin-bottom: 6px; }}
figcaption .sub {{ display: block; font-size: 13px; }}
svg {{ width: 100%; height: auto; display: block; }}
.grid {{ stroke: var(--grid); stroke-width: 1; }}
.baseline {{ stroke: var(--baseline); stroke-width: 1.5; stroke-dasharray: 3 3; }}
.tick {{ fill: var(--text-muted); font-size: 11.5px; }}
.glabel {{ fill: var(--text-primary); font-size: 13px; font-weight: 550; }}
.vlabel {{ fill: var(--text-secondary); font-size: 11.5px; }}
.whisker {{ stroke: var(--text-primary); stroke-opacity: 0.55; stroke-width: 1.5; }}
.mark {{ stroke: var(--surface-1); stroke-width: 2; }}
.mark:hover {{ filter: brightness(1.12); }}
#tip {{ position: fixed; pointer-events: none; background: var(--card); border: 1px solid var(--border);
       color: var(--text-primary); border-radius: 8px; padding: 7px 10px; font-size: 12.5px;
       max-width: 340px; display: none; z-index: 9; box-shadow: 0 4px 14px rgba(0,0,0,0.18); }}
table {{ border-collapse: collapse; width: 100%; font-size: 13px; margin-top: 10px; }}
th, td {{ text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); vertical-align: top; }}
thead th {{ color: var(--text-secondary); font-weight: 600; position: sticky; top: 0; background: var(--surface-1); }}
td.desc {{ color: var(--text-secondary); max-width: 210px; }}
.mm {{ color: var(--text-muted); font-size: 11px; display: block; }}
td.rss {{ color: var(--text-secondary); }}
td.win {{ color: var(--win); font-weight: 650; }}
td.lose {{ color: var(--lose); font-weight: 650; }}
.src-link {{ cursor: pointer; text-decoration: underline; text-decoration-style: dotted;
            text-decoration-color: var(--text-muted); text-underline-offset: 3px; }}
.src-link:hover {{ color: var(--c-puffin-arm64); fill: var(--c-puffin-arm64); }}
svg .src-link {{ text-decoration: none; }}
dialog#srcview {{ border: 1px solid var(--border); border-radius: 14px; padding: 0;
  width: min(860px, 92vw); background: var(--surface-1); color: var(--text-primary); }}
dialog#srcview::backdrop {{ background: rgba(20,20,18,0.35); backdrop-filter: blur(2px); }}
#srcview header {{ display: flex; align-items: center; gap: 12px; padding: 12px 18px;
  border-bottom: 1px solid var(--border); position: sticky; top: 0; background: var(--surface-1); }}
#srcview header .t {{ font-weight: 650; }}
#srcview header .d {{ color: var(--text-secondary); font-size: 12.5px; flex: 1; }}
#srcview .tabs {{ display: flex; gap: 4px; }}
#srcview .tabs button {{ font: inherit; font-size: 12.5px; padding: 3px 12px; border-radius: 999px;
  border: 1px solid var(--border); background: var(--card); color: var(--text-secondary); cursor: pointer; }}
#srcview .tabs button[aria-selected="true"] {{ background: var(--c-puffin-arm64); color: #fff; border-color: transparent; }}
#srcview .x {{ font: inherit; border: 0; background: none; color: var(--text-muted);
  cursor: pointer; font-size: 18px; line-height: 1; padding: 2px 6px; }}
#srcview pre {{ margin: 0; padding: 14px 18px 18px; overflow: auto; max-height: 68vh;
  font: 12.5px/1.5 ui-monospace, "SF Mono", Menlo, monospace; tab-size: 2; }}
#srcview .cm {{ color: var(--text-muted); font-style: italic; }}
#srcview .st {{ color: var(--c-puffin-x86); }}
#srcview .kw {{ color: var(--c-puffin-arm64); }}
.badge {{ display: inline-block; background: var(--card); border: 1px solid var(--border);
         border-radius: 999px; padding: 2px 11px; font-size: 12.5px; color: var(--text-secondary); margin: 2px 6px 2px 0; }}
</style>
<div class="viz-root">
<h1>Puffin vs Racket</h1>
<p class="lede">Nine paired benchmarks — the <em>same algorithm on both sides</em> — plus compile-time
measurements, run {meta['n_runs']}× each on {html.escape(meta['machine'])}.
Racket {html.escape(meta['racket_version'].replace('Welcome to Racket v', ''))} (Chez backend, bytecode pre-compiled
with <code>raco make</code>); Puffin via its native arm64 and x86-64 (Rosetta) backends.
All 27 program outputs agree byte-for-byte.</p>

<div class="tiles">
  <div class="tile"><div class="n">{geomean:.2f}×</div><div class="l">geometric-mean wall time vs Racket (arm64; &lt;1 is faster)</div></div>
  <div class="tile"><div class="n">{wins} / {len(ratio_rows)}</div><div class="l">benchmarks where Puffin arm64 beats Racket outright</div></div>
  <div class="tile"><div class="n">{meta['puffin_startup']*1000:.0f} ms vs {meta['racket_startup']*1000:.0f} ms</div><div class="l">process startup, Puffin binary vs <code>racket</code> (measured, subtract mentally for tiny scripts)</div></div>
  <div class="tile"><div class="n">189/189 ×3</div><div class="l">corpus golden checks: hosted arm64, hosted x86-64, and <strong>puffincc</strong> (the compiler written in Puffin)</div></div>
  <div class="tile"><div class="n">stage 3 ≡ stage 2</div><div class="l">self-hosting fixpoint: puffincc compiling itself is byte-identical</div></div>
</div>

<h2>Wall time by benchmark</h2>
<div class="legend">
  <span style="--sw: var(--c-puffin-arm64)">Puffin arm64 (native)</span>
  <span style="--sw: var(--c-puffin-x86)">Puffin x86-64 (Rosetta)</span>
  <span style="--sw: var(--c-racket)">Racket (Chez)</span>
</div>
{bar_chart("Median wall time", "seconds, lower is better; whiskers are min–max over runs", bench_rows)}
<p class="note">Wall time of the whole process. Startup overhead (tiles above) is included and
matters below ~0.3&nbsp;s on the Racket rows; every workload was sized so compute dominates.</p>

<h2>PL-course workloads</h2>
<p class="lede">Five workloads scaled up from the <code>pl-*</code> test suite (92-program corpus) —
the shapes a programming-languages course actually writes: deep pattern matching, list recursion,
persistent trees, backtracking search. Same paired-implementation rules as above.</p>
{bar_chart("Median wall time — PL workloads", "seconds, lower is better; whiskers are min-max over runs", pl_rows)}
<p class="note">Geometric mean on this group: <strong>{geomean_pl:.2f}× Racket</strong>. These
lean hard on small-cons allocation and quasipattern dispatch — Chez's strongest territory —
so this is the honest "your day-to-day code" number, distinct from the primitive-heavy suite above.</p>

<h2>Head-to-head ratio</h2>
{bar_chart("Puffin arm64 ÷ Racket", "log₂ scale centered at parity; left of the line = Puffin faster (all groups incl. PL)", ratio_rows, ratio_mode=True)}
<p class="note">The honest read: Chez's decades-tuned allocator and calling convention win on
allocation-heavy symbolic work (sort's 1M-cons churn, the meta-circular interpreter, HAMT path
copying) and raw recursion. Puffin's simple runtime wins where its C data structures shine —
open-addressing mutable hashes, vectors, byte-string building — and holds parity on lists.
Puffin allocates with Boehm (conservative, non-moving); Racket has a precise generational GC:
that difference is most of the sort/lists/hamt gap.</p>

<h2>Peak memory</h2>
{bar_chart("Peak resident set size", "MB, log scale — includes each runtime's baseline (Racket ≈ 108 MB, Puffin ≈ 2 MB)", rss_rows, unit="mb", log=True)}
<p class="note">Racket's floor is its runtime image; Puffin binaries start at ~2&nbsp;MB. The
lists row flips the other way: Boehm's conservative heap retains more of the 3M-cons workload
than Racket's precise collector.</p>

<h2>Compile time</h2>
{bar_chart("Compiling Puffin programs", "seconds, log scale; hosted = Racket-run reference compiler, puffincc = the self-hosted native compiler", ct_rows, log=True, link_names=False)}
<p class="note"><span class="src-link" data-prog="puffincc">puffincc</span> (a native binary produced
from ~3,000 lines of Puffin — click to read it) compiles <span class="src-link" data-prog="fib">fib</span>
in ~20&nbsp;ms and its own source in ~26&nbsp;s; the Racket-hosted reference takes ~32&nbsp;s on the
same input (it also runs predicate checks and provenance tagging that puffincc skips).
The hosted fib row includes clang assembly + linking; the puffincc rows are asm-out only.</p>

<h2>Full results</h2>
<table>
<thead><tr><th>benchmark</th><th>workload</th>
<th>Puffin arm64</th><th>RSS</th><th>Puffin x86-64</th><th>RSS</th><th>Racket</th><th>RSS</th><th>ratio</th></tr></thead>
<tbody>
{"".join(table_rows)}
</tbody>
</table>

<h2>Methodology & honesty notes</h2>
<p class="note">
<span class="badge">same algorithm both sides</span>
<span class="badge">median of {meta['n_runs']}, min–max whiskers</span>
<span class="badge">outputs verified equal</span>
<span class="badge">raco make for Racket</span>
<span class="badge">/usr/bin/time -l RSS</span>
</p>
<ul class="note">
<li>Racket's built-in <code>sort</code> and friends are <em>not</em> raced against Puffin's prelude:
both sides run the same hand-written merge sort, the same LCG, the same interpreter.
Racket's built-ins would do better; this measures the languages' execution of like code.</li>
<li>Racket numbers are arbitrary-precision; Puffin fixnums are 61-bit and unchecked. Workloads
stay within fixnum range (the sort PRNG was chosen for this), but Racket is doing
overflow checks Puffin skips — worth roughly its share of the fib/tail-loop gap.</li>
<li>Puffin's <code>vector-ref/set!</code> are checked runtime <em>calls</em> (not inlined), and every
closure call is a blind indirect jump with no arity check. Different safety trade-offs
than Racket's in both directions; see docs/BOOTSTRAP.md.</li>
<li>Deep non-tail recursion needed a 512&nbsp;MB stack reservation at link time (found by the 3M-element
<code>map</code>); Racket grows its stack dynamically. Real limitation, now documented.</li>
<li>Startup: Puffin {meta['puffin_startup']*1000:.0f} ms vs Racket {meta['racket_startup']*1000:.0f} ms.
For scripts that run shorter than ~0.5&nbsp;s this dominates everything above.</li>
</ul>
<p class="note">Reproduce: <code>python3 bench/run-benchmarks.py && python3 bench/build-report.py</code>.</p>
<dialog id="srcview">
  <header>
    <span class="t" id="sv-title"></span><span class="d" id="sv-desc"></span>
    <span class="tabs" id="sv-tabs"></span>
    <button class="x" id="sv-close" aria-label="close">×</button>
  </header>
  <pre id="sv-code"></pre>
</dialog>
<div id="tip"></div>
</div>
<script type="application/json" id="prog-sources">{sources_json}</script>
__VIEWER_SCRIPT__
<script>
const tip = document.getElementById('tip');
document.addEventListener('mouseover', e => {{
  const m = e.target.closest('[data-tip]');
  if (m) {{ tip.textContent = m.dataset.tip; tip.style.display = 'block'; }}
  else tip.style.display = 'none';
}});
document.addEventListener('mousemove', e => {{
  if (tip.style.display === 'block') {{
    const x = Math.min(e.clientX + 14, window.innerWidth - tip.offsetWidth - 8);
    const y = Math.min(e.clientY + 14, window.innerHeight - tip.offsetHeight - 8);
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
  }}
}});
</script>
"""
VIEWER = r"""<script>
const SRC = JSON.parse(document.getElementById('prog-sources').textContent);
const dlg = document.getElementById('srcview');
function hl(code) {
  let h = code.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  h = h.replace(/"(?:[^"\\]|\\.)*"/g, m => '\u0001' + m + '\u0002');
  h = h.replace(/(?<!&(?:lt|gt|amp));[^\n\u0001]*/g, m => '\u0003' + m + '\u0004');
  const KW = new Set(['define','lambda','match','let','let*','if','cond','case','when','unless','begin','set!','quote','quasiquote']);
  h = h.replace(/\(([^\s()\[\]]+)/g, (m, w) => KW.has(w) ? '(<span class="kw">' + w + '</span>' : m);
  return h.replace(/\u0001/g,'<span class="st">').replace(/\u0002/g,'</span>')
          .replace(/\u0003/g,'<span class="cm">').replace(/\u0004/g,'</span>');
}
function showSrc(name, side) {
  const p = SRC[name]; if (!p) return;
  side = side || (p.puffin ? 'puffin' : 'racket');
  document.getElementById('sv-title').textContent = name;
  document.getElementById('sv-desc').textContent = p.desc || '';
  const tabs = document.getElementById('sv-tabs');
  tabs.innerHTML = '';
  for (const t of ['puffin', 'racket']) {
    if (!p[t]) continue;
    const b = document.createElement('button');
    b.textContent = t === 'puffin' ? 'Puffin' : 'Racket';
    b.setAttribute('aria-selected', String(t === side));
    b.onclick = () => showSrc(name, t);
    tabs.appendChild(b);
  }
  document.getElementById('sv-code').innerHTML = hl(p[side]);
  if (!dlg.open) dlg.showModal();
}
document.addEventListener('click', e => {
  const l = e.target.closest('[data-prog]');
  if (l) { showSrc(l.getAttribute('data-prog')); return; }
  if (dlg.open && e.target === dlg) dlg.close();
});
document.getElementById('sv-close').onclick = () => dlg.close();
</script>"""
page = page.replace("__VIEWER_SCRIPT__", VIEWER)
open(os.path.join(BENCH, "report.html"), "w").write(page)
print(f"wrote bench/report.html  geomean={geomean:.3f} wins={wins}")
