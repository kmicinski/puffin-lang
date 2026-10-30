// What the live session holds of the program (studio/src/session.rs): for
// each file, the text each top-level form was loaded with, the last result
// of each expression evaluated from a buffer, and the observation record.
// The editor marks each form in the gutter as this tab types: a quiet dot
// when the session has it as shown, a hollow amber one when it was edited
// since it was loaded (or the prompt redefined it), nothing when the
// session lacks it.
//
//   createSession({ editor, files }) -> { receive, refresh, stateOf, statesOf, listing, observedOf, view }
//   stateOf(file, text, form)  { key, status, by, result }; status one of
//                              "current", "stale", "redefined", "evaluated", "absent"

import { forms } from "./lexer.js";

// A form's key, as the server's form scanner makes it (sexp.rs Form::key).
export function keyOf(form, index) {
  if (form.head === ":" && form.name) return `sig:${form.name}`;
  if (form.head?.startsWith("define") && form.name) return `${form.head}:${form.name}`;
  return `expr:${index}`;
}

const definition = (form) => Boolean(form.name && form.head?.startsWith("define"));
const expression = (form) => !definition(form) && !["require", "provide", ":"].includes(form.head);

const BY = { buffer: "⌘↵ / ,eval", file: ",load", prompt: "the prompt", types: "a unit's types" };

// What a form's gutter marker says, on hover.
export function describeState(state) {
  switch (state.status) {
    case "current": return `loaded in the session as shown (by ${BY[state.by] ?? state.by})`;
    case "stale": return "edited since it was loaded; ⌘↵ to reload";
    case "redefined": return "the prompt redefined it since; ⌘↵ loads this text";
    case "evaluated": return `evaluated: ⇒ ${state.result}`;
    default: return "not loaded in the session";
  }
}

export function createSession({ editor, files }) {
  let view = { files: {}, results: {}, observed: [] };
  let timer = 0;

  function stateOf(file, text, form, index = 0) {
    const key = keyOf(form, index);
    const body = text.slice(form.start, form.end);
    const state = { key, line: form.line, status: "absent", by: null, result: null };
    if (expression(form)) {
      const result = view.results[file]?.[body];
      if (result !== undefined) Object.assign(state, { status: "evaluated", result });
      return state;
    }
    const loaded = view.files[file]?.[key];
    if (loaded) {
      state.by = loaded.by;
      state.status = loaded.text === body ? "current" : loaded.by === "prompt" ? "redefined" : "stale";
    }
    return state;
  }

  const statesOf = (file, text) => forms(text).map((form, i) => ({ form, state: stateOf(file, text, form, i) }));

  // The shown file's gutter.
  function refresh() {
    const file = files.active();
    if (!file) return;
    const marks = statesOf(file, editor.get())
      .filter(({ state }) => state.status !== "absent")
      .map(({ form, state }) => ({ line: form.line, className: `session-glyph ${state.status}`, hover: describeState(state) }));
    editor.glyphs(file, marks);
  }

  // Typing: the gutter follows shortly after.
  function changed() {
    clearTimeout(timer);
    timer = setTimeout(refresh, 120);
  }

  // `,session`: what the session holds, file by file.
  function listing() {
    const texts = files.texts();
    const lines = [];
    for (const path of files.paths()) {
      const held = statesOf(path, texts[path] ?? "").filter(({ state }) => state.status !== "absent");
      if (!held.length) continue;
      lines.push(path);
      for (const { form, state } of held) {
        const mark = { current: "●", stale: "○", redefined: "○", evaluated: "⇒" }[state.status];
        const what = state.status === "evaluated" ? `${texts[path].slice(form.start, form.end).split("\n")[0].slice(0, 60)}  ⇒ ${state.result}` : state.key;
        lines.push(`  ${mark} ${what}${state.status === "current" || state.status === "evaluated" ? "" : `  (${state.status})`}  line ${form.line}`);
      }
    }
    for (const observed of view.observed) {
      if (lines.length && !lines.includes("observed")) lines.push("observed");
      lines.push(`  ${observed.function}: ${observed.calls} call${observed.calls === 1 ? "" : "s"}`);
    }
    return lines.length ? lines.join("\n") : "the session holds nothing of the program yet: ⌘↵ on a form, or Load file";
  }

  return {
    refresh,
    changed,
    stateOf,
    statesOf,
    listing,
    observedOf: (name) => view.observed.find((observed) => observed.function === name) ?? null,
    view: () => view,
    receive: {
      init(snapshot) {
        view = snapshot.session ?? view;
        refresh();
      },
      session(message) {
        view = { files: message.files, results: message.results, observed: message.observed };
        refresh();
      },
    },
  };
}
