// Markdown, as the agent writes it, to HTML: paragraphs, headings, lists
// (nested), block quotes, fenced code (with a copy button),
// tables, rules, and inline code, emphasis and links. Ported from Slog
// Studio's markdown.js; Puffin code is coloured as the editor colours it.
//
// Every character of the source reaches the output escaped; the only markup
// is what this module writes. Links go only to http(s) and mailto URLs.
// A fence still open at the end is a code block, so a reply renders
// sensibly while it streams.

import { tokens } from "./lexer.js";
import { KEYWORDS } from "./editor.js";

const KEYWORD = new Set(KEYWORDS);

export const escape = (text) =>
  text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c]);

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([\w+-]*)/;
const HEADING = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const RULE = /^ {0,3}([-*_])(\s*\1){2,}\s*$/;
const QUOTE = /^ {0,3}> ?/;
const ITEM = /^(\s*)([-*+]|\d{1,9}[.)])(\s+|$)/;
const TABLE_RULE = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
const blank = (line) => !line.trim();

export function markdown(text) {
  return blocks(text.replace(/\r\n?/g, "\n").split("\n"));
}

function blocks(lines) {
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    let match;
    if (blank(line)) {
      i++;
    } else if ((match = FENCE.exec(line))) {
      const [, fence, lang] = match;
      const body = [];
      for (i++; i < lines.length && !lines[i].trim().startsWith(fence); i++) body.push(lines[i]);
      i++;
      out.push(code(body.join("\n"), lang.toLowerCase()));
    } else if ((match = HEADING.exec(line))) {
      const level = match[1].length;
      out.push(`<h${level}>${inline(match[2])}</h${level}>`);
      i++;
    } else if (RULE.test(line)) {
      out.push("<hr>");
      i++;
    } else if (QUOTE.test(line)) {
      const body = [];
      for (; i < lines.length && QUOTE.test(lines[i]); i++) body.push(lines[i].replace(QUOTE, ""));
      out.push(`<blockquote>${blocks(body)}</blockquote>`);
    } else if (line.includes("|") && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1]) && lines[i + 1].includes("-")) {
      const rows = [line, lines[i + 1]];
      for (i += 2; i < lines.length && lines[i].includes("|") && !blank(lines[i]); i++) rows.push(lines[i]);
      out.push(table(rows));
    } else if (ITEM.test(line)) {
      const end = listEnd(lines, i);
      out.push(list(lines.slice(i, end)));
      i = end;
    } else {
      const body = [];
      for (; i < lines.length && !blank(lines[i]) && !startsBlock(lines, i); i++) body.push(lines[i].trim());
      if (!body.length) body.push(lines[i++].trim());
      out.push(`<p>${inline(body.join("\n"))}</p>`);
    }
  }
  return out.join("");
}

// Whether line `i` starts a block other than a paragraph, so a paragraph
// ends before it.
function startsBlock(lines, i) {
  const line = lines[i];
  return FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line) || ITEM.test(line)
    || (line.includes("|") && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1]) && lines[i + 1].includes("-"));
}

// ---- Lists ------------------------------------------------------------------

const indentOf = (line) => line.match(/^\s*/)[0].replace(/\t/g, "    ").length;

// Where the list starting at line `start` ends: at a blank line not followed
// by more of it, or at a line indented less than its items that is not one.
function listEnd(lines, start) {
  const base = indentOf(lines[start]);
  let i = start + 1;
  while (i < lines.length) {
    const line = lines[i];
    if (blank(line)) {
      const next = lines.slice(i).findIndex((l) => !blank(l));
      if (next < 0) break;
      const after = lines[i + next];
      if (indentOf(after) > base || (ITEM.test(after) && indentOf(after) === base)) { i += next; continue; }
      break;
    }
    if (indentOf(line) < base) break;
    if (indentOf(line) === base && !ITEM.test(line) && startsBlock(lines, i)) break;
    i++;
  }
  return i;
}

// A list's lines: the items at its first line's indent, each with the lines
// under it, rendered as blocks of their own.
function list(lines) {
  const base = indentOf(lines[0]);
  const first = ITEM.exec(lines[0]);
  const ordered = /\d/.test(first[2]);
  const items = [];
  for (const line of lines) {
    const match = ITEM.exec(line);
    if (match && indentOf(line) === base) {
      items.push({ lines: [line.slice(match[0].length)], width: match[0].length });
    } else {
      const item = items[items.length - 1];
      // continuation lines lose the item's indent, so nested lists start at 0
      item.lines.push(line.slice(Math.min(indentOf(line), item.width)));
    }
  }
  const loose = lines.some((line, i) => blank(line) && i < lines.length - 1);
  const body = items.map(({ lines: own }) => {
    const html = blocks(own);
    // a tight item's single paragraph is just its text
    return `<li>${loose ? html : html.replace(/^<p>([\s\S]*?)<\/p>/, "$1")}</li>`;
  });
  const start = ordered && parseInt(first[2], 10) !== 1 ? ` start="${parseInt(first[2], 10)}"` : "";
  return ordered ? `<ol${start}>${body.join("")}</ol>` : `<ul>${body.join("")}</ul>`;
}

// ---- Tables -----------------------------------------------------------------

function cells(row) {
  const trimmed = row.trim().replace(/^\|/, "").replace(/(?<!\\)\|$/, "");
  return trimmed.split(/(?<!\\)\|/).map((cell) => cell.trim().replace(/\\\|/g, "|"));
}

function table([head, rule, ...rows]) {
  const aligns = cells(rule).map((cell) =>
    cell.startsWith(":") && cell.endsWith(":") ? "center" : cell.endsWith(":") ? "right" : cell.startsWith(":") ? "left" : "");
  const row = (tag, row) => `<tr>${cells(row).map((cell, i) => {
    const align = aligns[i] ? ` style="text-align:${aligns[i]}"` : "";
    return `<${tag}${align}>${inline(cell)}</${tag}>`;
  }).join("")}</tr>`;
  return `<div class="md-table"><table><thead>${row("th", head)}</thead>` +
    `<tbody>${rows.map((r) => row("td", r)).join("")}</tbody></table></div>`;
}

// ---- Code -------------------------------------------------------------------

const PUFFIN = new Set(["puffin", "scheme", "racket", "lisp", "repl", "puf"]);

function code(text, lang) {
  const body = PUFFIN.has(lang) ? highlight(text) : escape(text);
  const label = lang ? `<span class="code-lang">${escape(lang)}</span>` : "";
  return `<div class="code-block">${label}<button type="button" class="copy" title="Copy">Copy</button>` +
    `<pre><code>${body}</code></pre></div>`;
}

// Puffin source as HTML, coloured as the editor colours it: keywords,
// constructors, strings, numbers and comments.
export function highlight(text) {
  let out = "";
  let at = 0;
  let previous = null;
  for (const token of tokens(text)) {
    out += escape(text.slice(at, token.start));
    const word = text.slice(token.start, token.end);
    out += span(kindOf(token, word, previous), word);
    at = token.end;
    previous = token;
  }
  return out + escape(text.slice(at));
}

function kindOf(token, word) {
  if (token.kind === "comment") return "comment";
  if (token.kind === "string") return "string";
  if (token.kind === "prefix") return "operator";
  if (token.kind !== "word") return "";
  if (KEYWORD.has(word)) return "keyword";
  if (/^[+-]?\d+$/.test(word) || /^#[tf]$/.test(word)) return "number";
  if (/^[A-Z]/.test(word)) return "type";
  return "";
}

const span = (kind, text) => kind ? `<span class="tok-${kind}">${escape(text)}</span>` : escape(text);

// ---- Inline -----------------------------------------------------------------

// Code spans, links and URLs, which emphasis must not reach into.
const ATOMS = /(`+)([\s\S]*?[^`])\1(?!`)|\[([^\]\n]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|<(https?:\/\/[^>\s]+)>|\bhttps?:\/\/[^\s<]*[^\s<.,;:!?)\]'"*_]/g;

export function inline(text) {
  const atoms = [];
  const hold = (html) => `\u0000${atoms.push(html) - 1}\u0000`;
  const held = text.replace(ATOMS, (whole, ticks, body, label, href, angled) => {
    if (ticks) return hold(`<code>${escape(body.replace(/^ (.*) $/s, "$1"))}</code>`);
    if (label) return hold(link(href, inline(label), whole));
    return hold(link(angled ?? whole, escape(angled ?? whole), whole));
  });
  return emphasis(escape(held).replace(/\n/g, " "))
    .replace(/\u0000(\d+)\u0000/g, (_, n) => atoms[Number(n)]);
}

function link(href, html, source) {
  if (!/^(https?:\/\/|mailto:)/i.test(href)) return escape(source);
  return `<a href="${escape(href)}" target="_blank" rel="noopener noreferrer">${html}</a>`;
}

// Emphasis in already escaped text: the patterns only add tags around it.
function emphasis(html) {
  return html
    .replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/g, "$1<strong>$2</strong>")
    .replace(/\*([^\s*](?:[^*]*?[^\s*])?)\*/g, "<em>$1</em>")
    .replace(/(^|[^\w])_([^\s_](?:[^_]*?[^\s_])?)_(?!\w)/g, "$1<em>$2</em>")
    .replace(/~~(?=\S)([\s\S]*?\S)~~/g, "<del>$1</del>");
}
