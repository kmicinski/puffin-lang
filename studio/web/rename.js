// Rename (F2): a small input at the cursor, prefilled with the name there.
// Enter asks the compiler (`puffincc --assist rename FILE POS NEW`), which
// answers the edits, or why not (the new name would capture another
// binding; the cursor is on no name). The edits apply as one undoable
// change, echoed as `,rename FILE:POS NEW` (POS a byte offset), which typed
// at the prompt does the same. It edits the one file: when other modules
// use a top-level name it renames, a note says which. Shown only when this
// puffincc can rename.
//
//   createRename({ editor, files, send, note }) -> { open, run, receive, setAvailable }

import { tokens } from "./lexer.js";
import { utf16Of } from "./assists.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// The word of `text` at `pos` (or ending at it): { start, end, word }.
export function nameAt(text, pos) {
  const token = tokens(text).find((t) => t.kind === "word" && t.start <= pos && pos <= t.end);
  return token ? { start: token.start, end: token.end, word: text.slice(token.start, token.end) } : null;
}

export function createRename({ editor, files, send, note }) {
  const waiting = new Map(); // seq -> resolve
  let seq = 0;
  let available = false;
  const box = document.body.appendChild(element("div", "rename-box"));
  box.hidden = true;
  const input = box.appendChild(element("input", "rename-input"));
  input.spellcheck = false;
  const said = box.appendChild(element("div", "rename-error"));
  let target = null; // { file, start, word }

  function request(file, pos, name) {
    files.flush();
    const id = ++seq;
    return new Promise((resolve) => {
      waiting.set(id, resolve);
      files.send({ t: "rename", seq: id, file, pos, name });
    });
  }

  // F2: the input over the name at the cursor.
  function open() {
    const file = files.active();
    if (!file || !available) return;
    const found = nameAt(editor.get(), editor.offset());
    if (!found) return note("no name at the cursor to rename");
    target = { file, start: found.start, word: found.word };
    said.textContent = "";
    box.hidden = false;
    const caret = editor.caretBox();
    if (caret) {
      box.style.left = `${Math.min(caret.left, innerWidth - 260)}px`;
      box.style.top = `${caret.top + caret.height + 4}px`;
    }
    input.value = found.word;
    input.focus();
    input.select();
  }

  function close() {
    box.hidden = true;
    target = null;
  }

  // Rename at UTF-16 offset `pos` of `file` to `name`; the error, if any.
  async function rename(file, pos, name) {
    const reply = await request(file, pos, name);
    if (reply.error) return reply.error;
    if (reply.version !== files.version(file) || !files.synced(file)) return "the text changed while the compiler looked; try again";
    if (files.active() !== file) files.open(file);
    if (reply.edits.length) editor.edits(reply.edits);
    send({ t: "echo", line: `,rename ${file}:${reply.pos} ${name}` });
    if (reply.note) note(reply.note);
    return null;
  }

  input.addEventListener("keydown", async (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close();
      editor.focus();
    } else if (event.key === "Enter") {
      event.preventDefault();
      const name = input.value.trim();
      if (!target || !name) return;
      if (name === target.word) return close();
      const { file, start } = target;
      said.textContent = "…";
      const error = await rename(file, start, name);
      if (error) {
        said.textContent = error;
        return;
      }
      close();
      editor.focus();
    }
  });
  input.addEventListener("blur", () => setTimeout(() => { if (document.activeElement !== input) close(); }, 150));

  // `,rename FILE:POS NEW` typed at the prompt: POS is a byte offset.
  async function run(file, bytes, name) {
    if (!available) return note("this puffincc has no --assist rename");
    if (!files.paths().includes(file)) return note(`no file ${file}`);
    const pos = utf16Of(files.texts()[file] ?? "", bytes);
    const error = await rename(file, pos, name);
    if (error) note(`cannot rename: ${error}`);
  }

  return {
    open,
    run,
    setAvailable(on) {
      available = Boolean(on);
      editor.setRenameAvailable(available);
    },
    receive: {
      renamed(reply) {
        waiting.get(reply.seq)?.(reply);
        waiting.delete(reply.seq);
      },
    },
  };
}
