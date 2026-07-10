// Web Worker that runs a whole Puffin program. The main thread
// terminates + respawns this worker to cancel an in-flight run.
//
// Output is buffered and flushed in chunks so a tight println loop
// doesn't flood the message channel but output still streams while
// the (synchronous) interpreter is running.

import { run } from './engine/index.js';

let buffer = '';
let lastFlush = 0;

function flush() {
  if (buffer !== '') {
    postMessage({ type: 'output', text: buffer });
    buffer = '';
  }
  lastFlush = Date.now();
}

function out(s) {
  buffer += s;
  if (buffer.length > 8192 || Date.now() - lastFlush > 50) flush();
}

onmessage = async (e) => {
  const msg = e.data;
  if (msg.type !== 'run') return;
  const t0 = performance.now();
  let res;
  try {
    // run() is async (the VM engine compiles on the wasm VM); the JS
    // interpreter path resolves immediately.
    res = await run(msg.source, {
      input: msg.input, onOutput: out,
      files: msg.files || null, entry: msg.entry || null,
    });
  } catch (err) {
    res = { ok: false, error: `internal error: ${err && err.message}` };
  }
  flush();
  postMessage({
    type: 'done',
    ok: res.ok,
    value: res.ok ? res.value : null,
    error: res.ok ? null : res.error,
    elapsed: performance.now() - t0,
  });
};
