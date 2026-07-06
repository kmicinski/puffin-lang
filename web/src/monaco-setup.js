// Monaco editor setup: self-hosted worker, the "puffin" language
// (s-expression tokenizer), and a Solarized Light theme.

import * as monaco from 'monaco-editor/esm/vs/editor/editor.api';
import editorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';
import { surfacePrimNames } from './puffin/index.js';

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

export function createEditor(el, value) {
  const m = setupMonaco();
  return m.editor.create(el, {
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
}
