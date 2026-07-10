// Persistent Web Worker hosting the REPL session: top-level defines
// persist across evals until the main thread sends 'reset' (or
// respawns the worker).
//
// The engine is resolved on the main thread and passed in the reset
// message (a Worker can't read ?engine= itself; same pattern as
// run-worker.js). 'js' = the hand-written interpreter Session
// (default); 'vm' = the bytecode-VM Session (docs/WASM-VM.md §5.2):
// a persistent wasm reactor instance running puffincc-compiled
// link-by-name units. Session.eval is awaited uniformly -- the JS
// Session's sync result resolves at once.

import { createSession, setEngine } from './engine/index.js';

let session = null;
let input = [];

function makeSession() {
  session = createSession({
    input,
    onOutput: (s) => postMessage({ type: 'output', text: s }),
  });
}

onmessage = async (e) => {
  const msg = e.data;
  switch (msg.type) {
    case 'reset':
      if (msg.engine) setEngine(msg.engine);
      input = msg.input || [];
      makeSession();
      postMessage({ type: 'reset-done' });
      break;
    case 'eval': {
      if (session === null) makeSession();
      let r;
      try {
        r = await session.eval(msg.code);
      } catch (err) {
        r = { ok: false, results: [], error: `internal error: ${err && err.message}` };
      }
      postMessage({
        type: 'result',
        id: msg.id,
        ok: r.ok,
        results: r.results,
        error: r.ok ? null : r.error,
      });
      break;
    }
  }
};
