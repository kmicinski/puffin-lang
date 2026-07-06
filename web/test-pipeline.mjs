// Sanity check for the pipeline span-tree builder (src/pipeline-model.js).
// Loads the bundled sample trace and, for every layer, verifies that the
// generated markup is balanced, properly nested, covers the text exactly,
// and that provenance resolution terminates. Run with: node test-pipeline.mjs

import { readFileSync } from 'node:fs';
import {
  buildLayer,
  renderLayerHTML,
  resolveBack,
  reverseIndex,
  collectReverseHits,
  breadcrumbChain,
  snippet,
} from './src/pipeline-model.js';

const trace = JSON.parse(readFileSync(new URL('./src/sample-trace.json', import.meta.url), 'utf8'));

let failures = 0;
function check(cond, msg) {
  if (!cond) {
    failures++;
    console.error(`  FAIL: ${msg}`);
  }
}

function unescapeHTML(s) {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

const layers = trace.passes.map(buildLayer);

for (let i = 0; i < layers.length; i++) {
  const layer = layers[i];
  const pass = trace.passes[i];
  let html;
  try {
    html = renderLayerHTML(layer); // throws on overlapping spans
  } catch (e) {
    failures++;
    console.error(`${layer.name}: builder threw: ${e.message}`);
    continue;
  }

  // 1. balanced, properly nested markup: tokenize and stack-parse
  const tokens = html.match(/<span data-id="[^"]*">|<\/span>|[^<]+/g) ?? [];
  check(tokens.join('') === html, `${layer.name}: tokenizer did not cover full markup (stray '<'?)`);
  let depth = 0;
  let minDepth = 0;
  let text = '';
  const seen = new Set();
  for (const tok of tokens) {
    if (tok.startsWith('<span')) {
      depth++;
      const id = Number(tok.slice(15, -2));
      check(!seen.has(id), `${layer.name}: duplicate data-id ${id}`);
      seen.add(id);
    } else if (tok === '</span>') {
      depth--;
      minDepth = Math.min(minDepth, depth);
    } else {
      text += unescapeHTML(tok);
    }
  }
  check(depth === 0, `${layer.name}: unbalanced spans (final depth ${depth})`);
  check(minDepth >= 0, `${layer.name}: close-before-open (min depth ${minDepth})`);

  // 2. stripping the markup reproduces the layer text exactly
  check(text === layer.text, `${layer.name}: reconstructed text differs from pass text`);

  // 3. every node got exactly one span
  check(seen.size === layer.byId.size, `${layer.name}: ${seen.size} spans for ${layer.byId.size} nodes`);
  for (const id of layer.byId.keys()) check(seen.has(id), `${layer.name}: node ${id} missing from markup`);

  // 4. render-asm gets one synthesized span per line
  if (pass.lineBack) {
    check(layer.byId.size === layer.text.split('\n').length, `${layer.name}: line-span count mismatch`);
  }

  // 5. provenance: every own-back target exists in the previous layer, and
  //    ancestor-walk resolution + full breadcrumb chains terminate
  if (i > 0) {
    const prev = layers[i - 1];
    for (const [id, t] of layer.back) {
      check(layer.byId.has(id), `${layer.name}: back key ${id} is not a node`);
      check(prev.byId.has(t), `${layer.name}: back target ${t} missing in ${prev.name}`);
    }
    let resolved = 0;
    for (const id of layer.byId.keys()) if (resolveBack(layer, id) !== null) resolved++;
    const chain = breadcrumbChain(layers, i, layer.roots[0].id);
    check(chain.length >= 1 && chain[chain.length - 1].layer === i, `${layer.name}: bad breadcrumb chain`);
    for (const c of chain) check(snippet(layers[c.layer], c.id) !== undefined, `${layer.name}: crumb snippet failed`);
    console.log(
      `ok  ${layer.name.padEnd(24)} nodes=${String(layer.byId.size).padStart(5)}  html=${String(html.length).padStart(7)}  resolved-back=${resolved}/${layer.byId.size}  chain-depth=${chain.length}`
    );
  } else {
    console.log(`ok  ${layer.name.padEnd(24)} nodes=${String(layer.byId.size).padStart(5)}  html=${String(html.length).padStart(7)}`);
  }
}

// 6. reverse index round-trip: hits collected from a left node must all
//    resolve (own back) into that node's subtree
for (let i = 1; i < layers.length; i++) {
  const left = layers[i - 1];
  const right = layers[i];
  const rev = reverseIndex(right);
  const root = left.roots[0];
  const hits = collectReverseHits(left, root.id, rev);
  for (const h of hits.slice(0, 200)) {
    let t = right.back.get(h);
    let n = left.byId.get(t);
    let found = false;
    while (n) {
      if (n.id === root.id) { found = true; break; }
      n = n.parent === -1 ? null : left.byId.get(n.parent);
    }
    check(found, `${right.name}: reverse hit ${h} escapes subtree of ${left.name}#${root.id}`);
  }
}

if (failures) {
  console.error(`\n${failures} check(s) FAILED`);
  process.exit(1);
} else {
  console.log(`\nall checks passed for ${layers.length} layers`);
}
