// The Facts panel: what each layer knows of the top-level form at the
// cursor (docs/STUDIO.md §3; studio/src/facts.rs), each labelled with the
// layer it came from:
//   Syntax    the form's key and lines (the form scanner)
//   Checker   the type at the cursor and the form's diagnostics
//   Session   whether the live session has the form as shown, and an
//             expression's last result
//   Observed  what the session's runs passed the function: per parameter,
//             the shapes seen and the compiler's patterns from them
// Syntax and Session are this tab's, so they follow typing at once; the
// rest come from the studio a moment after the cursor settles.
//
//   createFacts({ panel, toggle, editor, files, session, send })
//     -> { ask, cursor, refresh, receive, setFeatures }
//   ask(file, pos, full)   the studio's facts at UTF-16 offset `pos`

import { formAt, forms } from "./lexer.js";
import { describeState, keyOf } from "./session.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const SETTLE = 250;
const MARKS = { current: "●", stale: "○", redefined: "○", evaluated: "⇒", absent: "·" };

export function createFacts({ panel, toggle, editor, files, session, send }) {
  const waiting = new Map(); // seq -> resolve
  let seq = 0;
  let open = false;
  let timer = 0;
  let features = { observe: false, facts: false, assist: false };
  let known = null; // { file, version, pos, facts } of the last answer
  let asked = 0;

  // The studio's facts, behind any edit still in flight.
  function ask(file, pos, full = false) {
    files.flush();
    const id = ++seq;
    return new Promise((resolve) => {
      waiting.set(id, resolve);
      send({ t: "facts", seq: id, file, pos, full });
    });
  }

  function show(on) {
    open = on;
    panel.hidden = !on;
    toggle.setAttribute("aria-pressed", String(on));
    try { localStorage.setItem("puffin-studio.facts", on ? "1" : ""); } catch { /* private mode */ }
    if (on) refresh();
  }
  toggle.addEventListener("click", () => show(!open));

  // The cursor moved, or the text or what is known changed: render what
  // this tab knows now, and ask the studio once things settle.
  function cursor() {
    if (!open) return;
    render();
    clearTimeout(timer);
    timer = setTimeout(fetch, SETTLE);
  }
  const refresh = cursor;

  async function fetch() {
    const file = files.active();
    if (!open || !file) return;
    if (!files.synced(file)) {
      timer = setTimeout(fetch, SETTLE);
      return;
    }
    const pos = editor.selection().end;
    const mine = ++asked;
    const reply = await ask(file, pos, true);
    if (mine !== asked || reply.version !== files.version(file)) return;
    known = { file, version: reply.version, pos, facts: reply.facts, error: reply.error };
    render();
  }

  function section(name, source, ...children) {
    const box = element("section", "facts-layer");
    const head = box.appendChild(element("div", "facts-layer-head"));
    head.append(element("span", "facts-layer-name", name), element("span", "facts-source", source));
    box.append(...children.filter(Boolean));
    return box;
  }

  function render() {
    if (!open) return;
    const file = files.active();
    panel.replaceChildren();
    const head = panel.appendChild(element("div", "versions-head"));
    head.append(element("span", "", "Facts at the cursor"));
    const x = head.appendChild(element("button", "quiet small", "×"));
    x.addEventListener("click", () => show(false));
    if (!file) return;
    const text = editor.get();
    const pos = editor.selection().end;
    const all = forms(text);
    const form = formAt(all, pos);
    if (!form) {
      panel.append(element("p", "hint", "Put the cursor in a top-level form."));
      return;
    }
    const index = all.indexOf(form);
    // an answer for this form stands, dimmed, until the one for the
    // cursor's new place comes
    const fresh = known && known.file === file && known.version === files.version(file) && files.synced(file)
      && known.facts?.form?.line === form.line;
    const facts = fresh ? known.facts : null;
    const settling = fresh && known.pos !== pos;

    // Syntax
    const where = element("div", "facts-row");
    where.append(element("code", "", keyOf(form, index)), element("span", "hint", ` lines ${form.line}–${form.endLine}`));
    panel.append(section("Syntax", "the form scanner", where));

    // Checker
    const checker = [];
    if (!features.assist) checker.push(element("div", "hint", "this puffincc has no --assist: no types"));
    else if (!facts) checker.push(element("div", "hint", "…"));
    else {
      const word = wordAt(text, pos);
      const type = element("div", `facts-row${settling ? " settling" : ""}`);
      if (facts.type) type.append(element("code", "", `${word ? `${word} : ` : ""}${facts.type}`));
      else type.append(element("span", "hint", word ? `no type for ${word}` : "no type here"));
      checker.push(type);
      for (const d of facts.diagnostics ?? []) {
        checker.push(element("div", `facts-diagnostic ${d.severity}`, `${d.severity === "error" ? "✗" : "⚠"} ${d.message}  line ${d.line}`));
      }
      if (known.error && !facts.type) checker.push(element("div", "facts-diagnostic error", known.error));
    }
    panel.append(section("Checker", "puffincc", ...checker));

    // Session: this tab compares what was loaded with what it shows
    const state = session.stateOf(file, text, form, index);
    const live = element("div", `facts-row session-${state.status}`);
    live.append(element("span", "facts-mark", MARKS[state.status]), element("span", "", ` ${describeState(state)}`));
    panel.append(section("Session", "the live session", live));

    // Observed
    const observed = [];
    const function_ = facts?.function;
    if (!features.observe) observed.push(element("div", "hint", "off: this puffincc cannot observe (--repl --observe)"));
    else if (!form.head?.startsWith("define") || !/^\(\s*define\s*\(/.test(text.slice(form.start, form.end))) {
      observed.push(element("div", "hint", "observations are of function defines"));
    } else if (!facts) observed.push(element("div", "hint", "…"));
    else if (!function_) observed.push(element("div", "hint", "no calls seen yet: evaluate one"));
    else {
      observed.push(element("div", "facts-row", `${function_.name} — seen in ${function_.calls} call${function_.calls === 1 ? "" : "s"}`));
      for (const param of function_.params) {
        const row = observed[observed.push(element("div", "facts-param")) - 1];
        row.append(element("code", "facts-param-name", param.name));
        const list = row.appendChild(element("div", "facts-shapes"));
        const patterns = param.patterns?.length ? param.patterns : null;
        for (const shape of patterns ?? param.shapes) list.append(element("code", patterns ? "pattern" : "shape", shape));
        if (!param.shapes.length) list.append(element("span", "hint", "nothing yet"));
      }
    }
    panel.append(section("Observed", "runs in this session · sampled", ...observed));
  }

  // The word at `pos`, for labelling the type.
  function wordAt(text, pos) {
    const delimiter = /[\s()[\]";'`,]/;
    let start = pos;
    let end = pos;
    while (start > 0 && !delimiter.test(text[start - 1])) start--;
    while (end < text.length && !delimiter.test(text[end])) end++;
    return text.slice(start, end);
  }

  try { if (localStorage.getItem("puffin-studio.facts")) show(true); } catch { /* private mode */ }

  return {
    ask,
    cursor,
    refresh,
    setFeatures(next) {
      features = next;
      render();
    },
    receive: {
      facts(reply) {
        waiting.get(reply.seq)?.(reply);
        waiting.delete(reply.seq);
      },
    },
  };
}
