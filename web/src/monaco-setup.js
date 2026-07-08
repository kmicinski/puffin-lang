// Monaco editor setup: self-hosted worker, the "puffin" language
// (s-expression tokenizer), and a Solarized Light theme.

import * as monaco from 'monaco-editor/esm/vs/editor/editor.api';
// editor.api is the slim entry point and does NOT include the wordOperations
// contrib, so the cursorWord* commands used by the emacs bindings (M-f, M-b,
// M-d, M-backspace) would silently no-op without this import. It also
// restores standard Alt/Ctrl+Arrow word navigation as a bonus.
import 'monaco-editor/esm/vs/editor/contrib/wordOperations/browser/wordOperations.js';
import editorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';
import { surfacePrimNames } from './engine/index.js';

self.MonacoEnvironment = {
  getWorker() { return new editorWorker(); },
};

// Solarized Light palette
const SOL = {
  base3: 'fdf6e3', base2: 'eee8d5', base1: '93a1a1', base0: '839496',
  base00: '657b83', base01: '586e75', base02: '073642',
  yellow: 'b58900', orange: 'cb4b16', red: 'dc322f', magenta: 'd33682',
  violet: '6c71c4', blue: '268bd2', cyan: '2aa198', green: '859900',
};

const KEYWORDS = [
  'define', 'lambda', 'λ', 'let', 'let*', 'if', 'cond', 'case', 'match',
  'when', 'unless', 'begin', 'while', 'set!', 'quote', 'quasiquote',
  'unquote', 'and', 'or', 'not', 'else', 'program',
];

const BUILTINS = [...surfacePrimNames(), 'list', 'vector', '<=', '>', '>=', '<', 'eq?', '+', '-', '*'];

let initialized = false;

export function setupMonaco() {
  if (initialized) return monaco;
  initialized = true;

  monaco.languages.register({ id: 'puffin' });

  monaco.languages.setLanguageConfiguration('puffin', {
    comments: { lineComment: ';;' },
    brackets: [['(', ')'], ['[', ']']],
    autoClosingPairs: [
      { open: '(', close: ')' },
      { open: '[', close: ']' },
      { open: '"', close: '"', notIn: ['string'] },
    ],
    surroundingPairs: [
      { open: '(', close: ')' },
      { open: '[', close: ']' },
      { open: '"', close: '"' },
    ],
  });

  monaco.languages.setMonarchTokensProvider('puffin', {
    defaultToken: 'identifier',
    keywords: KEYWORDS,
    builtins: BUILTINS,
    tokenizer: {
      root: [
        [/;.*$/, 'comment'],
        [/"(?:[^"\\]|\\.)*"/, 'string'],
        [/"(?:[^"\\]|\\.)*$/, 'string.invalid'],
        [/#:[^\s()[\];"]+/, 'keyword.flag'],
        [/#t\b|#f\b|#true\b|#false\b/, 'constant.boolean'],
        [/'[^\s()[\];",'`]+/, 'symbol.quoted'],
        [/[+-]?\d+(?=[\s()[\];"]|$)/, 'number'],
        [/[()[\]]/, '@brackets'],
        [/[`',]/, 'operator.quote'],
        [/[^\s()[\];",'`]+/, {
          cases: {
            '@keywords': 'keyword',
            '@builtins': 'builtin',
            '@default': 'identifier',
          },
        }],
      ],
    },
  });

  monaco.editor.defineTheme('puffin-solarized', {
    base: 'vs',
    inherit: true,
    rules: [
      { token: 'comment', foreground: SOL.base1, fontStyle: 'italic' },
      { token: 'string', foreground: SOL.cyan },
      { token: 'string.invalid', foreground: SOL.red },
      { token: 'number', foreground: SOL.magenta },
      { token: 'constant.boolean', foreground: SOL.magenta },
      { token: 'symbol.quoted', foreground: SOL.yellow },
      { token: 'keyword', foreground: SOL.green, fontStyle: 'bold' },
      { token: 'keyword.flag', foreground: SOL.orange },
      { token: 'builtin', foreground: SOL.blue },
      { token: 'identifier', foreground: SOL.base00 },
      { token: 'operator.quote', foreground: SOL.orange },
      { token: 'delimiter.parenthesis', foreground: SOL.base01 },
      { token: 'delimiter.square', foreground: SOL.base01 },
    ],
    colors: {
      'editor.background': '#' + SOL.base3,
      'editor.foreground': '#' + SOL.base00,
      'editor.lineHighlightBackground': '#eee8d580',
      'editor.selectionBackground': '#' + SOL.base2,
      'editorCursor.foreground': '#' + SOL.base01,
      'editorLineNumber.foreground': '#' + SOL.base1,
      'editorLineNumber.activeForeground': '#' + SOL.base01,
      'editorBracketMatch.background': '#' + SOL.base2,
      'editorBracketMatch.border': '#' + SOL.yellow,
      'editorIndentGuide.background1': '#eee8d5',
      'editorWhitespace.foreground': '#eee8d5',
      'scrollbarSlider.background': '#93a1a133',
      'scrollbarSlider.hoverBackground': '#93a1a155',
      'editorBracketHighlight.foreground1': '#' + SOL.blue,
      'editorBracketHighlight.foreground2': '#' + SOL.magenta,
      'editorBracketHighlight.foreground3': '#' + SOL.cyan,
      'editorBracketHighlight.foreground4': '#' + SOL.violet,
    },
  });

  return monaco;
}

// ---------------------------------------------------------------------------
// Emacs-style keybindings
//
// Hand-rolled via editor.addCommand — deliberately not a full emacs-mode
// dependency. Notes / quirks:
//   - On macOS, Monaco's KeyMod.CtrlCmd means *Cmd*; emacs users want the
//     Control key, which is KeyMod.WinCtrl on mac. On Windows/Linux the
//     Control key is CtrlCmd. Hence the platform switch below.
//   - Meta is Alt/Option (KeyMod.Alt). Intercepting Alt+f etc. means you can
//     no longer type mac Option-glyphs ("ƒ", "∂", ...) in the editor — an
//     acceptable trade for an s-expression editor.
//   - These bindings shadow some Monaco/browser defaults when the editor is
//     focused: Ctrl+Space (suggest), and on Windows/Linux Ctrl+F (find),
//     Ctrl+A (select all), Ctrl+X/W (cut/close-tab is swallowed by Monaco's
//     preventDefault where the browser allows it). Ctrl+N on Windows cannot
//     be intercepted by any web page.
//   - The kill ring is module-level (shared by all editors on the page,
//     like a real emacs) and capped at KILL_RING_MAX entries.

const killRing = [];
const KILL_RING_MAX = 20;
const KILL_CMDS = new Set(['kill-line', 'kill-word', 'kill-word-back', 'kill-region']);

function pushKill(text, mode) {
  if (!text) return;
  if (mode && killRing.length > 0) {
    // Consecutive kills coalesce into one ring entry (emacs behavior):
    // forward kills append, backward kills prepend.
    const i = killRing.length - 1;
    killRing[i] = mode === 'prepend' ? text + killRing[i] : killRing[i] + text;
  } else {
    killRing.push(text);
    if (killRing.length > KILL_RING_MAX) killRing.shift();
  }
}

function installEmacsBindings(m, editor) {
  const isMac = /Mac|iP(hone|ad|od)/.test(navigator.platform || '');
  const Ctrl = isMac ? m.KeyMod.WinCtrl : m.KeyMod.CtrlCmd; // the *Control* key
  const Meta = m.KeyMod.Alt;
  const K = m.KeyCode;
  const WHEN = 'textInputFocus'; // only when this editor has focus

  const st = {
    busy: false,      // true while one of our commands is running
    lastCmd: null,    // for C-k coalescing and M-y chaining
    mark: false,      // C-space mark mode: motions extend the selection
    yankIndex: -1,
    yankRange: null,  // range of the last yank, replaced by M-y
    runHandler: null, // captured Cmd/Ctrl+Enter Run handler (see below)
  };

  // Any cursor/content change *not* caused by our commands (mouse click,
  // plain typing, arrow keys, setValue) breaks kill/yank chains & mark mode.
  editor.onDidChangeCursorPosition(() => {
    if (!st.busy) { st.lastCmd = null; st.mark = false; }
  });
  editor.onDidChangeModelContent(() => {
    if (!st.busy) { st.lastCmd = null; st.mark = false; }
  });

  const bind = (keys, name, fn) => {
    editor.addCommand(keys, () => {
      st.busy = true;
      let override;
      try { override = fn(); } finally { st.busy = false; }
      st.lastCmd = typeof override === 'string' ? override : name;
    }, WHEN);
  };

  const collapseSelection = () => {
    const p = editor.getPosition();
    editor.setSelection(new m.Selection(p.lineNumber, p.column, p.lineNumber, p.column));
  };

  // --- motion (uses Monaco core cursor commands; *Select variant in mark mode)
  const move = (plain, select) => () => {
    editor.trigger('emacs', st.mark ? select : plain, null);
  };
  bind(Ctrl | K.KeyF, 'motion', move('cursorRight', 'cursorRightSelect'));
  bind(Ctrl | K.KeyB, 'motion', move('cursorLeft', 'cursorLeftSelect'));
  bind(Ctrl | K.KeyN, 'motion', move('cursorDown', 'cursorDownSelect'));
  bind(Ctrl | K.KeyP, 'motion', move('cursorUp', 'cursorUpSelect'));
  bind(Ctrl | K.KeyA, 'motion', move('cursorLineStart', 'cursorLineStartSelect'));
  bind(Ctrl | K.KeyE, 'motion', move('cursorLineEnd', 'cursorLineEndSelect'));
  bind(Meta | K.KeyF, 'motion', move('cursorWordEndRight', 'cursorWordEndRightSelect'));
  bind(Meta | K.KeyB, 'motion', move('cursorWordStartLeft', 'cursorWordStartLeftSelect'));
  // M-< / M-> are Alt+Shift+Comma / Alt+Shift+Period (US layout).
  bind(Meta | m.KeyMod.Shift | K.Comma, 'motion', move('cursorTop', 'cursorTopSelect'));
  bind(Meta | m.KeyMod.Shift | K.Period, 'motion', move('cursorBottom', 'cursorBottomSelect'));

  // --- kill commands
  bind(Ctrl | K.KeyK, 'kill-line', () => {
    const model = editor.getModel();
    const pos = editor.getPosition();
    const maxCol = model.getLineMaxColumn(pos.lineNumber);
    let range;
    if (pos.column >= maxCol) {
      // At end of line: kill the newline (emacs kill-line).
      if (pos.lineNumber >= model.getLineCount()) return 'nop';
      range = new m.Range(pos.lineNumber, pos.column, pos.lineNumber + 1, 1);
    } else {
      range = new m.Range(pos.lineNumber, pos.column, pos.lineNumber, maxCol);
    }
    pushKill(model.getValueInRange(range), KILL_CMDS.has(st.lastCmd) ? 'append' : null);
    editor.pushUndoStop();
    editor.executeEdits('emacs', [{ range, text: '' }]);
  });

  const killByMotion = (selectCmd, mode) => () => {
    collapseSelection();
    editor.trigger('emacs', selectCmd, null);
    const sel = editor.getSelection();
    if (sel.isEmpty()) return 'nop';
    pushKill(editor.getModel().getValueInRange(sel), KILL_CMDS.has(st.lastCmd) ? mode : null);
    editor.executeEdits('emacs', [{ range: sel, text: '' }]);
  };
  bind(Meta | K.KeyD, 'kill-word', killByMotion('cursorWordEndRightSelect', 'append'));
  bind(Meta | K.Backspace, 'kill-word-back', killByMotion('cursorWordStartLeftSelect', 'prepend'));

  // --- mark / region
  bind(Ctrl | K.Space, 'set-mark', () => {
    if (st.mark) { st.mark = false; collapseSelection(); }
    else st.mark = true;
  });
  bind(Ctrl | K.KeyG, 'cancel', () => {
    st.mark = false;
    collapseSelection();
  });
  bind(Ctrl | K.KeyW, 'kill-region', () => {
    const sel = editor.getSelection();
    if (sel.isEmpty()) return 'nop';
    pushKill(editor.getModel().getValueInRange(sel), null);
    editor.pushUndoStop();
    editor.executeEdits('emacs', [{ range: sel, text: '' }]);
    st.mark = false;
  });
  bind(Meta | K.KeyW, 'copy-region', () => {
    const sel = editor.getSelection();
    if (sel.isEmpty()) return 'nop';
    pushKill(editor.getModel().getValueInRange(sel), null);
    collapseSelection();
    st.mark = false;
  });

  // --- yank
  const insertAt = (range, text) => {
    editor.executeEdits('emacs', [{ range, text, forceMoveMarkers: true }]);
    const lines = text.split('\n');
    const endLine = range.startLineNumber + lines.length - 1;
    const endCol = lines.length === 1
      ? range.startColumn + text.length
      : lines[lines.length - 1].length + 1;
    st.yankRange = new m.Range(range.startLineNumber, range.startColumn, endLine, endCol);
    editor.setSelection(new m.Selection(endLine, endCol, endLine, endCol));
  };
  bind(Ctrl | K.KeyY, 'yank', () => {
    if (killRing.length === 0) return 'nop';
    st.yankIndex = killRing.length - 1;
    editor.pushUndoStop();
    insertAt(editor.getSelection(), killRing[st.yankIndex]);
    st.mark = false;
  });
  bind(Meta | K.KeyY, 'yank-pop', () => {
    // Only valid immediately after C-y / M-y, like emacs yank-pop.
    if (st.lastCmd !== 'yank' && st.lastCmd !== 'yank-pop') return 'nop';
    if (killRing.length === 0 || !st.yankRange) return 'nop';
    st.yankIndex = (st.yankIndex - 1 + killRing.length) % killRing.length;
    insertAt(st.yankRange, killRing[st.yankIndex]);
  });

  // --- C-x chords
  // Note: registering C-x as a chord prefix means plain Ctrl+X no longer
  // cuts on Windows/Linux while the editor is focused (use C-w).
  bind(m.KeyMod.chord(Ctrl | K.KeyX, Ctrl | K.KeyS), 'save-run', () => {
    if (st.runHandler) { st.runHandler(); return; }
    // No Run handler wired up: brief opacity flash so the key isn't silent.
    const node = editor.getDomNode();
    if (node) {
      node.style.transition = 'opacity 80ms';
      node.style.opacity = '0.6';
      setTimeout(() => { node.style.opacity = ''; }, 90);
    }
  });
  bind(m.KeyMod.chord(Ctrl | K.KeyX, K.KeyU), 'undo', () => {
    editor.trigger('emacs', 'undo', null);
  });

  // Capture the app's Run handler: App.jsx binds Cmd/Ctrl+Enter via
  // editor.addCommand *after* createEditor returns, so shim addCommand and
  // remember the handler registered under that exact keybinding. This keeps
  // the existing Cmd+Enter binding fully intact.
  const runKey = m.KeyMod.CtrlCmd | K.Enter;
  const origAddCommand = editor.addCommand.bind(editor);
  editor.addCommand = (keybinding, handler, context) => {
    if (keybinding === runKey) st.runHandler = handler;
    return origAddCommand(keybinding, handler, context);
  };
}

export function createEditor(el, value) {
  const m = setupMonaco();
  // Subtle discoverability hint (native tooltip; no layout change).
  el.title = 'Emacs keys: C-f/b/n/p move · C-a/e line · M-f/b word · M-d/M-DEL kill word · '
    + 'C-k kill line · C-y yank, M-y cycle · C-SPC mark · C-w/M-w kill/copy region · '
    + 'C-x C-s run · C-x u undo · M-< / M-> top/bottom · C-g cancel';
  const editor = m.editor.create(el, {
    value,
    language: 'puffin',
    theme: 'puffin-solarized',
    fontSize: 14,
    fontFamily: "'SF Mono', Menlo, Monaco, 'Cascadia Code', monospace",
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    automaticLayout: true,
    matchBrackets: 'always',
    bracketPairColorization: { enabled: true },
    autoClosingBrackets: 'always',
    tabSize: 2,
    renderLineHighlight: 'line',
    wordWrap: 'off',
    padding: { top: 10 },
  });
  installEmacsBindings(m, editor);
  return editor;
}
