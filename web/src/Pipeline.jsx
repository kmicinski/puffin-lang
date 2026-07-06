import { createSignal, createEffect, onMount, onCleanup, For, Show } from 'solid-js';
import {
  buildLayer,
  renderLayerHTML,
  resolveBack,
  reverseIndex,
  collectReverseHits,
  breadcrumbChain,
  snippet,
} from './pipeline-model.js';

const TRACE_URL = 'http://localhost:8899/trace';
const SAMPLE_NOTICE = 'showing the bundled sample — start `racket src/ir-server.rkt` to trace your own code';

// props: getSource() -> current Playground editor text, active() -> pipeline mode visible
export default function Pipeline(props) {
  const [passNames, setPassNames] = createSignal([]);
  const [passIdx, setPassIdx] = createSignal(0);
  const [version, setVersion] = createSignal(0); // bumped when a new trace loads
  const [notice, setNotice] = createSignal('');
  const [traceLabel, setTraceLabel] = createSignal('');
  const [target, setTarget] = createSignal('arm64');
  const [tracing, setTracing] = createSignal(false);
  const [crumbs, setCrumbs] = createSignal([]);

  // Non-reactive heavy state: layers hold thousands of nodes, so the panes are
  // rendered imperatively (one innerHTML build per layer, memoized) with event
  // delegation, instead of per-node Solid components.
  let layers = [];
  let htmlCache = [];
  let revCache = [];
  let leftPre, rightPre, railEl;
  let leftEls = new Map(); // node id -> span element (rebuilt per pane render)
  let rightEls = new Map();
  let hovered = null;
  let marked = []; // elements carrying highlight classes, cleared on next action
  let pendingSel = null; // {id, scroll} to apply after the next pane render

  function layerHTML(i) {
    if (htmlCache[i] === undefined) htmlCache[i] = renderLayerHTML(layers[i]);
    return htmlCache[i];
  }
  function revIdx(i) {
    if (revCache[i] === undefined) revCache[i] = reverseIndex(layers[i]);
    return revCache[i];
  }

  function collectEls(pre) {
    const m = new Map();
    for (const el of pre.querySelectorAll('span[data-id]')) m.set(Number(el.dataset.id), el);
    return m;
  }

  function clearMarks() {
    for (const el of marked) el.classList.remove('sel', 'back-hit', 'rev-hit');
    marked = [];
  }
  function mark(el, cls) {
    if (el) {
      el.classList.add(cls);
      marked.push(el);
    }
  }

  // re-render both panes whenever the selected pass (or the trace) changes
  createEffect(() => {
    const i = passIdx();
    version();
    if (!layers.length || !rightPre) return;
    clearMarks();
    hovered = null;
    rightPre.innerHTML = layerHTML(i);
    rightEls = collectEls(rightPre);
    if (i > 0) {
      leftPre.innerHTML = layerHTML(i - 1);
      leftEls = collectEls(leftPre);
    } else {
      leftPre.innerHTML = '<span class="pipe-empty">source is the first layer — nothing before it</span>';
      leftEls = new Map();
    }
    leftPre.scrollTop = 0;
    rightPre.scrollTop = 0;
    railEl?.children[i]?.scrollIntoView({ block: 'nearest' });
    if (pendingSel) {
      const p = pendingSel;
      pendingSel = null;
      selectRightNode(p.id, { scroll: p.scroll, rebuildCrumbs: false });
    }
  });

  // Select a node in the RIGHT pane: strong highlight, mark its provenance
  // target in the LEFT pane (ancestor-walk via resolveBack), scroll it into
  // view, and rebuild the breadcrumb chain back to source.
  function selectRightNode(id, opts = {}) {
    const i = passIdx();
    clearMarks();
    const el = rightEls.get(id);
    mark(el, 'sel');
    if (el && opts.scroll) el.scrollIntoView({ block: 'center' });
    if (i > 0) {
      const t = resolveBack(layers[i], id);
      if (t !== null && t !== undefined) {
        const lel = leftEls.get(t);
        mark(lel, 'back-hit');
        if (lel) lel.scrollIntoView({ block: 'center' });
      }
    }
    if (opts.rebuildCrumbs !== false) rebuildCrumbs(i, id);
  }

  // Select a node in the LEFT pane: reverse-map it — highlight every node in
  // the RIGHT pane whose back edge lands on it or any of its descendants.
  function selectLeftNode(id) {
    const i = passIdx();
    if (i === 0) return;
    clearMarks();
    mark(leftEls.get(id), 'sel');
    const hits = collectReverseHits(layers[i - 1], id, revIdx(i));
    hits.sort((a, b) => (layers[i].byId.get(a)?.start ?? 0) - (layers[i].byId.get(b)?.start ?? 0));
    let first = null;
    for (const h of hits) {
      const el = rightEls.get(h);
      if (el) {
        mark(el, 'rev-hit');
        if (!first) first = el;
      }
    }
    if (first) first.scrollIntoView({ block: 'center' });
    rebuildCrumbs(i - 1, id);
  }

  function rebuildCrumbs(layerIdx, id) {
    const chain = breadcrumbChain(layers, layerIdx, id);
    setCrumbs(
      chain.map((c) => ({
        layer: c.layer,
        id: c.id,
        name: layers[c.layer].name,
        snip: snippet(layers[c.layer], c.id),
      }))
    );
  }

  function jumpToCrumb(c) {
    if (c.layer === passIdx()) {
      selectRightNode(c.id, { scroll: true, rebuildCrumbs: false });
    } else {
      pendingSel = { id: c.id, scroll: true };
      setPassIdx(c.layer);
    }
  }

  // ---------- delegated pane events ----------

  function hoverHandler(ev) {
    const el = ev.target.closest?.('span[data-id]'); // closest = innermost span
    if (el === hovered) return;
    if (hovered) hovered.classList.remove('hov');
    hovered = el || null;
    if (hovered) hovered.classList.add('hov');
  }
  function leaveHandler() {
    if (hovered) {
      hovered.classList.remove('hov');
      hovered = null;
    }
  }
  function rightClick(ev) {
    const el = ev.target.closest?.('span[data-id]');
    if (el) selectRightNode(Number(el.dataset.id));
  }
  function leftClick(ev) {
    const el = ev.target.closest?.('span[data-id]');
    if (el) selectLeftNode(Number(el.dataset.id));
  }

  // ---------- ←/→ pass navigation ----------

  function onKey(ev) {
    if (!props.active()) return;
    const t = ev.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT')) return;
    if (ev.key === 'ArrowLeft') {
      ev.preventDefault();
      setPassIdx((i) => Math.max(0, i - 1));
    } else if (ev.key === 'ArrowRight') {
      ev.preventDefault();
      setPassIdx((i) => Math.min(layers.length - 1, i + 1));
    }
  }

  // ---------- trace loading ----------

  function loadTrace(json, label) {
    layers = json.passes.map(buildLayer);
    htmlCache = [];
    revCache = [];
    pendingSel = null;
    setCrumbs([]);
    setPassNames(json.passes.map((p) => p.name));
    if (json.target) setTarget(json.target);
    setTraceLabel(label);
    setPassIdx(layers.length > 1 ? 1 : 0);
    setVersion((v) => v + 1);
  }

  async function doTrace() {
    if (tracing()) return;
    setTracing(true);
    try {
      const res = await fetch(TRACE_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ source: props.getSource(), target: target() }),
      });
      const json = await res.json();
      if (json.error) {
        setNotice(`trace error: ${json.error}`);
      } else {
        loadTrace(json, `editor trace · ${json.target ?? target()}`);
        setNotice('');
      }
    } catch {
      setNotice(SAMPLE_NOTICE);
    }
    setTracing(false);
  }

  onMount(() => {
    window.addEventListener('keydown', onKey);
    // demo/fallback trace, loaded lazily so the Playground bundle stays lean
    import('./sample-trace.json').then(
      (mod) => {
        if (!layers.length) {
          loadTrace(mod.default, `bundled sample · ${mod.default.target}`);
          setNotice(SAMPLE_NOTICE);
        }
      },
      (e) => setNotice(`failed to load sample trace: ${e.message}`)
    );
  });
  onCleanup(() => window.removeEventListener('keydown', onKey));

  return (
    <section class="pipeline">
      <div class="pipe-toolbar">
        <button class="btn run" disabled={tracing()} onClick={doTrace} title="Compile the Playground editor source and trace every pass">
          {tracing() ? 'Tracing…' : 'Trace ▸'}
        </button>
        <select class="examples" value={target()} onChange={(e) => setTarget(e.target.value)} title="Target architecture">
          <option value="arm64">arm64</option>
          <option value="x86-64">x86-64</option>
        </select>
        <span class="trace-label">{traceLabel()}</span>
        <Show when={notice()}>
          <span class="pipe-notice">{notice()}</span>
        </Show>
        <span class="spacer" />
        <div class="pipe-legend">
          <span class="chip chip-sel" /> selected&thinsp;/&thinsp;origin
          <span class="chip chip-rev" /> became
          <span class="chip chip-hov" /> hover
          <span class="legend-keys">←/→ passes</span>
        </div>
      </div>

      <div class="pipe-body">
        <nav class="pass-rail" ref={railEl}>
          <For each={passNames()}>
            {(name, i) => (
              <div class="pass-step" classList={{ current: i() === passIdx() }} onClick={() => setPassIdx(i())}>
                <span class="idx">{i()}</span>
                <span class="pname">{name}</span>
              </div>
            )}
          </For>
        </nav>

        <div class="pipe-panes">
          <div class="pipe-pane">
            <div class="pane-title">
              {passIdx() > 0 ? passNames()[passIdx() - 1] : '·'}
              <span class="pane-hint">previous — click: what did this become?</span>
            </div>
            <pre ref={leftPre} onClick={leftClick} onMouseOver={hoverHandler} onMouseLeave={leaveHandler} />
          </div>
          <div class="pipe-pane">
            <div class="pane-title">
              {passNames()[passIdx()] ?? ''}
              <span class="pane-hint">click a node to see its origin</span>
            </div>
            <pre ref={rightPre} onClick={rightClick} onMouseOver={hoverHandler} onMouseLeave={leaveHandler} />
          </div>
        </div>
      </div>

      <Show when={crumbs().length > 0}>
        <div class="crumb-strip">
          <span class="crumb-title">provenance</span>
          <For each={crumbs()}>
            {(c) => (
              <div
                class="crumb"
                classList={{ active: c.layer === passIdx() }}
                onClick={() => jumpToCrumb(c)}
                title={`${c.name}: ${c.snip}`}
              >
                <span class="crumb-pass">{c.name}</span>
                <span class="crumb-snip">{c.snip}</span>
              </div>
            )}
          </For>
        </div>
      </Show>
    </section>
  );
}
