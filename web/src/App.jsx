import { createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { createEditor, setupMonaco } from './monaco-setup.js';
import { EXAMPLES } from './examples.js';

const MAX_LINES = 2000; // capped ring so the console stays smooth

function parseStdin(text) {
  return text.split(/\s+/).filter((s) => s !== '' && /^[+-]?\d+$/.test(s)).map(Number);
}

export default function App() {
  // ---------- console state ----------
  const [lines, setLines] = createSignal([]);
  const [truncated, setTruncated] = createSignal(false);
  let nextId = 0;
  let openOut = false; // is the last line an unterminated stdout line?
  let consoleEl;

  function pushLines(prev, items) {
    let next = prev.concat(items);
    if (next.length > MAX_LINES) {
      next = next.slice(next.length - MAX_LINES);
      setTruncated(true);
    }
    return next;
  }

  function scrollToBottom() {
    if (consoleEl) queueMicrotask(() => { consoleEl.scrollTop = consoleEl.scrollHeight; });
  }

  // whole lines with a class ('echo' | 'err' | 'sys' | 'val')
  function appendLine(text, cls) {
    openOut = false;
    setLines((prev) => pushLines(prev, [{ id: nextId++, text, cls }]));
    scrollToBottom();
  }

  // streaming program stdout: a chunk may end mid-line
  function appendOut(chunk) {
    if (chunk === '') return;
    const parts = chunk.split('\n');
    const endsWithNewline = parts[parts.length - 1] === '' && chunk.endsWith('\n');
    if (endsWithNewline) parts.pop();
    setLines((prev) => {
      let base = prev;
      const items = [];
      let i = 0;
      if (openOut && prev.length > 0) {
        // extend the in-progress line
        const last = prev[prev.length - 1];
        base = prev.slice(0, -1);
        items.push({ id: last.id, text: last.text + parts[0], cls: last.cls });
        i = 1;
      }
      for (; i < parts.length; i++) items.push({ id: nextId++, text: parts[i], cls: 'out' });
      return pushLines(base, items);
    });
    openOut = !endsWithNewline;
    scrollToBottom();
  }

  function clearConsole() {
    openOut = false;
    setTruncated(false);
    setLines([]);
  }

  // ---------- run state ----------
  const [running, setRunning] = createSignal(false);
  const [elapsed, setElapsed] = createSignal(0);
  const [stdinText, setStdinText] = createSignal('');
  let runWorker = null;
  let timer = null;
  let t0 = 0;

  function handleRunMessage(e) {
    const msg = e.data;
    if (msg.type === 'output') appendOut(msg.text);
    else if (msg.type === 'done') {
      stopTimer();
      setRunning(false);
      if (!msg.ok) appendLine(`error: ${msg.error}`, 'err');
      appendLine(`— finished in ${msg.elapsed < 1000 ? Math.round(msg.elapsed) + ' ms' : (msg.elapsed / 1000).toFixed(2) + ' s'}`, 'sys');
    }
  }

  function spawnRunWorker() {
    runWorker = new Worker(new URL('./run-worker.js', import.meta.url), { type: 'module' });
    runWorker.onmessage = handleRunMessage;
  }

  function startTimer() {
    t0 = Date.now();
    setElapsed(0);
    timer = setInterval(() => setElapsed(Date.now() - t0), 100);
  }
  function stopTimer() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  function doRun() {
    if (running()) { // cancel in-flight run: terminate + respawn
      runWorker.terminate();
      spawnRunWorker();
      stopTimer();
      appendLine('— run cancelled', 'sys');
    }
    openOut = false;
    appendLine('— run —', 'sys');
    setRunning(true);
    startTimer();
    runWorker.postMessage({ type: 'run', source: editor.getValue(), input: parseStdin(stdinText()) });
  }

  function doStop() {
    if (!running()) return;
    runWorker.terminate();
    spawnRunWorker();
    stopTimer();
    setRunning(false);
    appendLine('— run cancelled', 'sys');
  }

  // ---------- REPL state ----------
  const [replBusy, setReplBusy] = createSignal(false);
  const [replText, setReplText] = createSignal('');
  let replWorker = null;
  let history = [];
  let histIdx = -1;
  let replInputEl;

  function handleReplMessage(e) {
    const msg = e.data;
    if (msg.type === 'output') appendOut(msg.text);
    else if (msg.type === 'result') {
      setReplBusy(false);
      for (const r of msg.results) appendLine(r, 'val');
      if (!msg.ok) appendLine(`error: ${msg.error}`, 'err');
    } else if (msg.type === 'reset-done') {
      setReplBusy(false);
    }
  }

  function spawnReplWorker() {
    replWorker = new Worker(new URL('./repl-worker.js', import.meta.url), { type: 'module' });
    replWorker.onmessage = handleReplMessage;
    replWorker.postMessage({ type: 'reset', input: parseStdin(stdinText()) });
  }

  function resetSession() {
    replWorker.terminate(); // also kills a stuck eval
    spawnReplWorker();
    setReplBusy(false);
    appendLine('— REPL session reset —', 'sys');
  }

  function replSubmit() {
    const code = replText().trim();
    if (code === '' || replBusy()) return;
    history.push(code);
    histIdx = history.length;
    appendLine(`puffin> ${code}`, 'echo');
    setReplText('');
    setReplBusy(true);
    replWorker.postMessage({ type: 'eval', id: histIdx, code });
  }

  function replKeyDown(ev) {
    if (ev.key === 'Enter') { ev.preventDefault(); replSubmit(); }
    else if (ev.key === 'ArrowUp') {
      if (history.length === 0) return;
      ev.preventDefault();
      histIdx = Math.max(0, histIdx - 1);
      setReplText(history[histIdx]);
    } else if (ev.key === 'ArrowDown') {
      if (history.length === 0) return;
      ev.preventDefault();
      histIdx = Math.min(history.length, histIdx + 1);
      setReplText(histIdx === history.length ? '' : history[histIdx]);
    }
  }

  // ---------- editor ----------
  let editorEl;
  let editor;

  onMount(() => {
    const monaco = setupMonaco();
    editor = createEditor(editorEl, EXAMPLES[0].code);
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, doRun);
    spawnRunWorker();
    spawnReplWorker();
    appendLine('Welcome to Puffin — press Run, or type a form in the REPL below.', 'sys');
  });

  onCleanup(() => {
    stopTimer();
    if (runWorker) runWorker.terminate();
    if (replWorker) replWorker.terminate();
    if (editor) editor.dispose();
  });

  function loadExample(ev) {
    const ex = EXAMPLES.find((x) => x.id === ev.target.value);
    if (ex && editor) { editor.setValue(ex.code); editor.setScrollTop(0); }
  }

  return (
    <div class="app">
      <header class="header">
        <div class="brand">
          <span class="logo">🐧</span>
          <span class="name">Puffin</span>
          <span class="target-note">interpreter</span>
        </div>
        <button class="btn run" onClick={doRun} title="Run (Cmd/Ctrl+Enter)">Run ▸</button>
        <Show when={running()}>
          <button class="btn stop" onClick={doStop}>Stop</button>
        </Show>
        <select class="examples" onChange={loadExample} title="Load an example program">
          <For each={EXAMPLES}>
            {(ex) => <option value={ex.id}>{ex.label}</option>}
          </For>
        </select>
        <Show when={running()}>
          <div class="running-indicator">
            <span class="dot" />
            running… {(elapsed() / 1000).toFixed(1)}s
          </div>
        </Show>
      </header>

      <main class="main">
        <section class="editor-pane">
          <div class="monaco-host" ref={editorEl} />
        </section>

        <section class="right-pane">
          <div class="pane-title">
            Output
            <span class="spacer" />
            <button class="btn small" onClick={clearConsole}>Clear</button>
          </div>
          <div class="console" ref={consoleEl}>
            <Show when={truncated()}>
              <div class="truncated">… earlier output truncated (last {MAX_LINES} lines kept)</div>
            </Show>
            <For each={lines()}>
              {(l) => <div class={`line ${l.cls}`}>{l.text}</div>}
            </For>
          </div>

          <details class="stdin-box">
            <summary>stdin — integers for (read); empty = 0 1 2 …</summary>
            <textarea
              spellcheck={false}
              placeholder="e.g.  2 12 78 3 99"
              value={stdinText()}
              onInput={(e) => setStdinText(e.target.value)}
            />
          </details>

          <div class="repl">
            <span class="prompt">puffin&gt;</span>
            <input
              ref={replInputEl}
              type="text"
              spellcheck={false}
              placeholder={replBusy() ? 'evaluating…' : 'evaluate a form — defines persist (↑/↓ history)'}
              value={replText()}
              onInput={(e) => setReplText(e.target.value)}
              onKeyDown={replKeyDown}
            />
            <button class="btn small" onClick={resetSession} title="Discard all REPL definitions">
              Reset session
            </button>
          </div>
        </section>
      </main>
    </div>
  );
}
