// A trace as the session runtime prints it (docs/STUDIO.md §3.2;
// studio/observe.puf), the way Racket's trace does: `> (f args)` on each
// call and `< value` on its return, after one `| ` per level of depth. In
// the transcript a trace is a call tree: each call is a row with its
// arguments and the value it returned, and its nested calls below it.
// Calls past the third level start closed, as do calls once about forty
// rows show; a closed call says how many calls it holds, and a long list
// of calls ends in "N more calls". Output a traced call printed itself
// stays in place, as plain lines among its nested calls.
//
//   parseTrace(text) -> [{ text } | { calls }]   plain runs and traces, in order
//   renderOutput(text) -> a node, or null when `text` holds no trace
//   renderTrace(calls) -> a node: one trace's tree
//   hasTrace(text)

import { highlight } from "./markdown.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// Calls this deep and deeper start closed.
const OPEN_DEPTH = 3;
// Rows one opening shows before "N more calls".
const PAGE = 40;

const LINE = /^((?:\| )*)([<>]) (.*)$/;

export const hasTrace = (text) => /(^|\n)> \(/.test(text);

// Each call: { call, value (null: it never returned), children }; each
// plain line inside a call: { text }.
export function parseTrace(text) {
  const out = [];
  let plain = [];
  let stack = null; // [root, call at depth 0, call at depth 1, ...]
  const flush = () => {
    if (plain.length) out.push({ text: `${plain.join("\n")}\n` });
    plain = [];
  };
  const lines = text.split("\n");
  const tail = lines.pop();
  for (const line of lines) {
    const match = LINE.exec(line);
    const depth = match ? match[1].length / 2 : -1;
    if (match && match[2] === ">" && match[3].startsWith("(") && (stack ? depth < stack.length : depth === 0)) {
      if (!stack) {
        flush();
        stack = [{ children: [] }];
        out.push({ calls: stack[0].children });
      }
      // calls deeper than this one never returned
      stack.length = depth + 1;
      const call = { call: match[3], value: null, children: [] };
      stack[depth].children.push(call);
      stack.push(call);
    } else if (match && match[2] === "<" && stack && depth + 1 < stack.length) {
      stack[depth + 1].value = match[3];
      stack.length = depth + 1;
    } else if (stack && stack.length > 1) {
      stack.at(-1).children.push({ text: line });
    } else {
      stack = null;
      plain.push(line);
    }
  }
  if (tail) {
    if (stack && stack.length > 1) stack.at(-1).children.push({ text: tail });
    else plain.push(tail);
  }
  if (plain.length) out.push({ text: `${plain.join("\n")}${tail ? "" : "\n"}` });
  return out;
}

// How many calls `items` hold, nested ones included.
function count(items) {
  let n = 0;
  for (const item of items) if (item.children) n += 1 + count(item.children);
  return n;
}

function depthOf(items) {
  let deepest = 0;
  for (const item of items) if (item.children) deepest = Math.max(deepest, 1 + depthOf(item.children));
  return deepest;
}

export function renderTrace(calls) {
  const box = element("div", "trace");
  const head = box.appendChild(element("div", "trace-head"));
  const total = count(calls);
  head.append(element("span", "", `trace · ${total} call${total === 1 ? "" : "s"} · ${depthOf(calls)} deep`));
  const raw = head.appendChild(element("button", "trace-raw", "as text"));
  raw.title = "Show the trace as it was printed (Racket's layout), to read or copy";
  const tree = box.appendChild(element("div", "trace-tree"));
  appendItems(tree, calls, 0, { rows: PAGE });
  let text = null;
  raw.addEventListener("click", () => {
    if (!text) {
      text = box.appendChild(element("pre", "trace-text-view", printed(calls, 0)));
      text.hidden = true;
    }
    const showText = text.hidden;
    tree.hidden = showText;
    text.hidden = !showText;
    raw.textContent = showText ? "as a tree" : "as text";
  });
  return box;
}

// The trace as the runtime printed it.
function printed(items, depth) {
  const bars = "| ".repeat(depth);
  return items.map((item) => (item.children
    ? `${bars}> ${item.call}\n${printed(item.children, depth + 1)}${item.value === null ? "" : `${bars}< ${item.value}\n`}`
    : `${item.text}\n`)).join("");
}

function appendItems(container, items, depth, budget) {
  let i = 0;
  for (; i < items.length; i++) {
    if (budget.rows <= 0 && i > 0) break;
    container.append(renderItem(items[i], depth, budget));
  }
  if (i < items.length) {
    const rest = items.slice(i);
    const calls = count(rest);
    const more = container.appendChild(element("button", "trace-more",
      calls ? `${calls} more call${calls === 1 ? "" : "s"}` : `${rest.length} more line${rest.length === 1 ? "" : "s"}`));
    more.addEventListener("click", () => {
      more.remove();
      appendItems(container, rest, depth, { rows: PAGE });
    });
  }
}

function renderItem(item, depth, budget) {
  budget.rows--;
  if (!item.children) return element("pre", "trace-out", item.text);
  const node = element("div", "trace-call");
  const row = node.appendChild(element("div", "trace-row"));
  const toggle = row.appendChild(element("span", "trace-toggle"));
  const call = row.appendChild(element("code", "trace-args"));
  call.innerHTML = highlight(item.call);
  call.title = item.call;
  const value = row.appendChild(element("code", item.value === null ? "trace-value none" : "trace-value"));
  if (item.value === null) {
    value.textContent = "no return";
    value.title = "This call never returned: the evaluation failed or was interrupted inside it";
  } else {
    value.innerHTML = highlight(item.value);
    value.title = item.value;
  }
  const nested = count(item.children);
  if (!item.children.length) {
    node.classList.add("leaf");
    return node;
  }
  if (nested) row.append(element("span", "trace-count", `${nested} call${nested === 1 ? "" : "s"}`));
  const children = node.appendChild(element("div", "trace-children"));
  let filled = false;
  const open = (on, rows) => {
    node.classList.toggle("open", on);
    if (on && !filled) {
      filled = true;
      appendItems(children, item.children, depth + 1, rows ?? { rows: PAGE });
    }
  };
  row.title = "Click to open or close; ⌥-click opens every call inside";
  row.addEventListener("click", (event) => {
    if (event.altKey) return openAll(node, { rows: 2000 });
    open(!node.classList.contains("open"));
  });
  node.openTrace = open;
  if (depth + 1 < OPEN_DEPTH && budget.rows > 0) open(true, budget);
  return node;
}

// Open `node` and every call inside it, up to a bound of rows.
function openAll(node, budget) {
  node.openTrace?.(true, { rows: Infinity });
  for (const child of node.querySelectorAll(":scope > .trace-children > .trace-call:not(.leaf)")) {
    if (budget.rows-- <= 0) return;
    openAll(child, budget);
  }
}

// Program output with its traces drawn as trees, or null when it holds none.
export function renderOutput(text) {
  if (!hasTrace(text)) return null;
  const box = element("div", "stream out traced");
  for (const part of parseTrace(text)) {
    if (part.calls) box.append(renderTrace(part.calls));
    else box.append(element("pre", "stream out", part.text));
  }
  return box;
}
