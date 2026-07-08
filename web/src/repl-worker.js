// Persistent Web Worker hosting the REPL session: top-level defines
// persist across evals until the main thread sends 'reset' (or
// respawns the worker).

import { Session } from './engine/index.js';

let session = null;
let input = [];

function makeSession() {
  session = new Session({
    input,
    onOutput: (s) => postMessage({ type: 'output', text: s }),
  });
}

onmessage = (e) => {
  const msg = e.data;
  switch (msg.type) {
    case 'reset':
      input = msg.input || [];
      makeSession();
      postMessage({ type: 'reset-done' });
      break;
    case 'eval': {
      if (session === null) makeSession();
      const r = session.eval(msg.code);
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
