#!/usr/bin/env node
// Build the Puffin GitHub Pages site into _site/ at the repo root.
//
//   index.html            <- README.md (hero treatment)
//   docs/<NAME>.html      <- docs/<NAME>.md, one page per reference doc
//   docs/tutorial.html    <- copied verbatim (hand-written HTML)
//   docs/stdlib.html      <- copied verbatim (generated reference)
//   examples/index.html   <- examples/README.md
//
// Relative links between rendered pages are rewritten .md -> .html;
// links into the source tree (directories, .puf files, scripts) point
// at GitHub. No other build system is involved: `npm ci && npm run build`.

import { Marked } from 'marked';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, '_site');
const GITHUB = 'https://github.com/kmicinski/puffin-lang';

// Reference docs rendered from markdown, in nav order:
// [source stem, nav label, output filename]. STDLIB.md can't emit
// STDLIB.html — on a case-insensitive filesystem it collides with the
// verbatim-copied stdlib.html (the generated per-function reference).
const DOCS = [
  ['LANGUAGE', 'The language', 'LANGUAGE.html'],
  ['TYPES', 'Gradual types', 'TYPES.html'],
  ['MODULES', 'Modules', 'MODULES.html'],
  ['FFI', 'FFI', 'FFI.html'],
  ['STDLIB', 'Stdlib', 'stdlib-overview.html'],
  ['OPTIMIZER', 'Optimizer', 'OPTIMIZER.html'],
  ['BYTECODE', 'Bytecode', 'BYTECODE.html'],
  ['WASM-VM', 'Wasm VM', 'WASM-VM.html'],
  ['BOOTSTRAP', 'Bootstrap', 'BOOTSTRAP.html'],
  ['DELTA', 'Delta', 'DELTA.html'],
];
const DOC_OUT = new Map(DOCS.map(([name, , out]) => [`docs/${name}.md`, `docs/${out}`]));

// ---------------------------------------------------------------- utilities

const esc = (s) =>
  s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
   .replaceAll('"', '&quot;');

function slug(text, seen) {
  let s = text.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^\w\- ]+/g, '')
    .trim().replace(/\s+/g, '-');
  if (seen.has(s)) { let n = 1; while (seen.has(`${s}-${n}`)) n++; s = `${s}-${n}`; }
  seen.add(s);
  return s;
}

// ------------------------------------------------------- scheme highlighting

const KEYWORDS = new Set([
  'define', 'define-type', 'define-foreign-type', 'lambda', 'λ', 'let', 'let*',
  'letrec', 'if', 'cond', 'case', 'else', 'match', 'begin', 'set!', 'quote',
  'quasiquote', 'unquote', 'unquote-splicing', 'and', 'or', 'not', 'when',
  'unless', 'while', 'delay', 'force', 'require', 'provide', 'foreign', 'ann',
  'error', 'program',
]);

function highlightScheme(src) {
  const re = /(;[^\n]*)|("(?:[^"\\]|\\.)*")|(#[tf]\b|#\\[^\s()[\]]+|#%[\w!?<>=*+-]+|#:[\w-]+)|(-?\d+(?:\.\d+)?(?=[\s()[\]]|$))|([()[\]])|('[\w!?<>=*+./-]+)|([^\s()[\]";']+)/g;
  let out = '', last = 0, m;
  while ((m = re.exec(src))) {
    out += esc(src.slice(last, m.index));
    last = re.lastIndex;
    const t = m[0];
    if (m[1]) out += `<span class="c">${esc(t)}</span>`;
    else if (m[2]) out += `<span class="s">${esc(t)}</span>`;
    else if (m[3]) out += `<span class="h">${esc(t)}</span>`;
    else if (m[4]) out += `<span class="n">${esc(t)}</span>`;
    else if (m[5]) out += `<span class="p">${esc(t)}</span>`;
    else if (m[6]) out += `<span class="q">${esc(t)}</span>`;
    else if (KEYWORDS.has(t)) out += `<span class="k">${esc(t)}</span>`;
    else if (/^[A-Z]/.test(t)) out += `<span class="t">${esc(t)}</span>`;
    else if (t === ':' || t === '->' || t === '->*' || t === '_' || t === '...')
      out += `<span class="h">${esc(t)}</span>`;
    else out += esc(t);
  }
  return out + esc(src.slice(last));
}

function highlightShell(src) {
  return esc(src).replace(/(^|\n)(\s*)(#[^\n]*)/g,
    (_, a, b, c) => `${a}${b}<span class="c">${c}</span>`);
}

function renderCode(text, lang) {
  const body = lang === 'scheme' || lang === 'racket' || lang === 'puffin'
    ? highlightScheme(text)
    : highlightShell(text);
  return `<pre class="code lang-${lang || 'shell'}"><code>${body}</code></pre>\n`;
}

// ------------------------------------------------------------- link rewriting

// srcDir: repo-relative dir of the markdown file ('' for README).
// pageDir: repo-relative dir of the emitted html page.
function rewriteHref(href, srcDir, pageDir) {
  if (/^([a-z]+:|#|\/)/i.test(href)) return href; // absolute, anchor, rooted
  const [target, anchor] = href.split('#');
  const resolved = path.normalize(path.join(srcDir, target)).replaceAll(path.sep, '/');
  const hash = anchor ? `#${anchor}` : '';
  const rel = (p) => {
    const r = path.relative(pageDir, p).replaceAll(path.sep, '/');
    return (r || '.') + hash;
  };
  if (resolved === 'README.md') return rel('index.html');
  if (resolved === 'examples/README.md') return rel('examples/index.html');
  if (DOC_OUT.has(resolved)) return rel(DOC_OUT.get(resolved));
  if (resolved === 'docs/tutorial.html' || resolved === 'docs/stdlib.html') return rel(resolved);
  const abs = path.join(ROOT, resolved);
  if (fs.existsSync(abs)) {
    const kind = fs.statSync(abs).isDirectory() ? 'tree' : 'blob';
    return `${GITHUB}/${kind}/main/${resolved}${hash}`;
  }
  return href;
}

// ------------------------------------------------------------------ markdown

function renderMarkdown(mdSource, { srcDir, pageDir }) {
  const seen = new Set();
  const m = new Marked({ gfm: true });
  m.use({
    walkTokens(token) {
      if (token.type === 'link') token.href = rewriteHref(token.href, srcDir, pageDir);
    },
    renderer: {
      code(token) { return renderCode(token.text, (token.lang || '').trim()); },
      heading(token) {
        const html = this.parser.parseInline(token.tokens);
        const id = slug(token.text, seen);
        return `<h${token.depth} id="${id}"><a class="anchor" href="#${id}">${html}</a></h${token.depth}>\n`;
      },
    },
  });
  return m.parse(mdSource);
}

// ------------------------------------------------------------------ the shell

const LOGO = `<svg class="logo" viewBox="0 0 64 64" aria-hidden="true"><circle cx="29" cy="33" r="26" fill="var(--ink)"/><ellipse cx="22" cy="35" rx="15" ry="17" fill="var(--paper)"/><path d="M41 17 Q63 22 61 36 Q59 50 42 47 Q35 43 35 32 Q35 22 41 17Z" fill="#dc322f"/><path d="M41 17 Q55 20 58 28 L37 30 Q36 22 41 17Z" fill="#f2b53c"/><circle cx="24" cy="26" r="3.2" fill="var(--ink)"/></svg>`;

function page({ title, body, depth, active, description }) {
  const p = '../'.repeat(depth);
  const nav = (href, label, key) =>
    `<a href="${p}${href}"${active === key ? ' class="active"' : ''}>${label}</a>`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent(LOGO.replace('var(--ink)', '%23073642').replace('var(--paper)', '%23fdf6e3').replace('var(--ink)', '%23073642'))}">
<link rel="stylesheet" href="${p}style.css">
</head>
<body>
<header class="topbar">
  <a class="brand" href="${p}index.html">${LOGO}<span>Puffin</span></a>
  <nav>
    ${nav('docs/tutorial.html', 'Tutorial', 'tutorial')}
    ${nav('docs/stdlib.html', 'Stdlib', 'stdlib')}
    ${nav('docs/LANGUAGE.html', 'Docs', 'docs')}
    ${nav('examples/index.html', 'Examples', 'examples')}
    <a href="${GITHUB}" class="gh">GitHub</a>
  </nav>
</header>
${body}
<footer class="footer">
  <p>Puffin · MIT licensed · <a href="${GITHUB}">${GITHUB.replace('https://', '')}</a></p>
</footer>
</body>
</html>
`;
}

function docsStrip(depth, current) {
  const p = '../'.repeat(depth);
  const links = DOCS.map(([name, label, out]) =>
    `<a href="${p}docs/${out}"${name === current ? ' class="here"' : ''}>${label}</a>`);
  return `<nav class="docstrip"><span>Reference:</span> ${links.join(' ')}</nav>`;
}

// --------------------------------------------------------------------- build

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(path.join(OUT, 'docs'), { recursive: true });
fs.mkdirSync(path.join(OUT, 'examples'), { recursive: true });

// GitHub Pages: serve as-is, no Jekyll pass.
fs.writeFileSync(path.join(OUT, '.nojekyll'), '');
fs.copyFileSync(path.join(ROOT, 'site/style.css'), path.join(OUT, 'style.css'));

// Verbatim HTML docs (tutorial <-> stdlib link to each other as siblings).
for (const f of ['tutorial.html', 'stdlib.html'])
  fs.copyFileSync(path.join(ROOT, 'docs', f), path.join(OUT, 'docs', f));

const DESCRIPTION =
  'Puffin: a minimal Scheme/ML-like functional language — self-hosting compiler, gradual types, modules, and a typed FFI.';

// index.html <- README.md, with the leading `# Puffin` lifted into a hero.
{
  const md = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8')
    .replace(/^# Puffin\s*\n/, '');
  const body = renderMarkdown(md, { srcDir: '', pageDir: '' });
  const hero = `<section class="hero">
  ${LOGO.replace('class="logo"', 'class="logo hero-logo"')}
  <h1>Puffin</h1>
  <p class="tagline">A minimal Scheme/ML-like functional language — self-hosting
  compiler, gradual types, modules, and a typed FFI.</p>
  <p class="cta">
    <a class="button" href="#quick-start">Quick start</a>
    <a class="button" href="docs/tutorial.html">Puffin for Racketeers</a>
    <a class="button ghost" href="${GITHUB}">Source on GitHub</a>
  </p>
</section>`;
  fs.writeFileSync(path.join(OUT, 'index.html'), page({
    title: 'Puffin — a small, self-hosting functional language',
    description: DESCRIPTION,
    depth: 0, active: null,
    body: `${hero}\n<main class="prose">\n${body}\n</main>`,
  }));
}

// docs/<out> <- docs/<NAME>.md
for (const [name, label, out] of DOCS) {
  const md = fs.readFileSync(path.join(ROOT, 'docs', `${name}.md`), 'utf8');
  const body = renderMarkdown(md, { srcDir: 'docs', pageDir: 'docs' });
  fs.writeFileSync(path.join(OUT, 'docs', out), page({
    title: `${label} — Puffin`,
    description: `Puffin reference documentation: ${label}.`,
    depth: 1, active: 'docs',
    body: `${docsStrip(1, name)}\n<main class="prose">\n${body}\n</main>`,
  }));
}

// examples/index.html <- examples/README.md
{
  const md = fs.readFileSync(path.join(ROOT, 'examples', 'README.md'), 'utf8');
  const body = renderMarkdown(md, { srcDir: 'examples', pageDir: 'examples' });
  fs.writeFileSync(path.join(OUT, 'examples', 'index.html'), page({
    title: 'Examples — Puffin',
    description: 'Runnable Puffin examples, including the Z3 FFI binding.',
    depth: 1, active: 'examples',
    body: `<main class="prose">\n${body}\n</main>`,
  }));
}

const files = fs.readdirSync(OUT, { recursive: true }).filter((f) =>
  fs.statSync(path.join(OUT, f)).isFile());
console.log(`built _site/: ${files.length} files`);
for (const f of files.sort()) console.log(`  ${f}`);
