// TeX characters, DrRacket's way: type a TeX name after a backslash
// (`\lambda`, `\varsigma`, `\to`, `\_1`) and press ⌥↵ (Alt-Enter) to
// replace it with the character (λ, ς, →, ₁). An unfinished name that
// starts exactly one entry is completed the same way; one that starts
// several opens the completion list on them, and Enter there picks one.
// `compress` is the pure part; bindTex puts it on Monaco's Alt-Enter
// and on a plain text field's keydown (the REPL prompt).
// Ctrl-\ (DrRacket's key, the real Control key on a Mac too) types a λ
// straight away, in both places, replacing any selection.

// Ctrl-\ and nothing else held (Shift aside: some layouts need it for \)
const isLambdaKey = (event) =>
  event.ctrlKey && !event.altKey && !event.metaKey && (event.code === "Backslash" || event.key === "\\");

// the table: TeX name -> character
export const TEX = {
  // Greek
  alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", varepsilon: "ϵ", zeta: "ζ", eta: "η",
  theta: "θ", vartheta: "ϑ", iota: "ι", kappa: "κ", lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", omicron: "ο",
  pi: "π", varpi: "ϖ", rho: "ρ", varrho: "ϱ", sigma: "σ", varsigma: "ς", tau: "τ", upsilon: "υ",
  phi: "φ", varphi: "ϕ", chi: "χ", psi: "ψ", omega: "ω",
  Alpha: "Α", Beta: "Β", Gamma: "Γ", Delta: "Δ", Epsilon: "Ε", Zeta: "Ζ", Eta: "Η", Theta: "Θ", Iota: "Ι",
  Kappa: "Κ", Lambda: "Λ", Mu: "Μ", Nu: "Ν", Xi: "Ξ", Omicron: "Ο", Pi: "Π", Rho: "Ρ", Sigma: "Σ", Tau: "Τ",
  Upsilon: "Υ", Phi: "Φ", Chi: "Χ", Psi: "Ψ", Omega: "Ω",
  // arrows
  to: "→", rightarrow: "→", leftarrow: "←", leftrightarrow: "↔", Rightarrow: "⇒", Leftarrow: "⇐",
  Leftrightarrow: "⇔", mapsto: "↦", longmapsto: "⟼", uparrow: "↑", downarrow: "↓", updownarrow: "↕",
  Uparrow: "⇑", Downarrow: "⇓", longrightarrow: "⟶", longleftarrow: "⟵", Longrightarrow: "⟹",
  Longleftarrow: "⟸", hookrightarrow: "↪", hookleftarrow: "↩", rightharpoonup: "⇀", leftharpoonup: "↼",
  twoheadrightarrow: "↠", twoheadleftarrow: "↞", rightsquigarrow: "⇝", leadsto: "⇝", nearrow: "↗",
  searrow: "↘", swarrow: "↙", nwarrow: "↖", implies: "⟹", iff: "⟺",
  // logic
  forall: "∀", exists: "∃", nexists: "∄", neg: "¬", lnot: "¬", land: "∧", wedge: "∧", lor: "∨", vee: "∨",
  vdash: "⊢", dashv: "⊣", vDash: "⊨", models: "⊨", Vdash: "⊩", nvdash: "⊬", top: "⊤", bot: "⊥",
  therefore: "∴", because: "∵", bigwedge: "⋀", bigvee: "⋁",
  // sets
  in: "∈", notin: "∉", ni: "∋", subset: "⊂", subseteq: "⊆", subsetneq: "⊊", supset: "⊃", supseteq: "⊇",
  supsetneq: "⊋", cup: "∪", cap: "∩", bigcup: "⋃", bigcap: "⋂", emptyset: "∅", varnothing: "∅",
  setminus: "∖", sqsubset: "⊏", sqsubseteq: "⊑", sqsupset: "⊐", sqsupseteq: "⊒", sqcup: "⊔", sqcap: "⊓",
  bigsqcup: "⨆", bigsqcap: "⨅", uplus: "⊎", biguplus: "⨄", complement: "∁",
  // relations
  leq: "≤", le: "≤", geq: "≥", ge: "≥", neq: "≠", ne: "≠", equiv: "≡", nequiv: "≢", approx: "≈", sim: "∼",
  simeq: "≃", cong: "≅", ll: "≪", gg: "≫", prec: "≺", succ: "≻", preceq: "≼", succeq: "≽", propto: "∝",
  perp: "⊥", parallel: "∥", mid: "∣", nmid: "∤", triangleleft: "◁", triangleright: "▷",
  trianglelefteq: "⊴", trianglerighteq: "⊵", lesssim: "≲", gtrsim: "≳", doteq: "≐", defeq: "≝",
  // operators
  times: "×", div: "÷", pm: "±", mp: "∓", cdot: "⋅", circ: "∘", bullet: "•", oplus: "⊕", ominus: "⊖",
  otimes: "⊗", oslash: "⊘", odot: "⊙", star: "⋆", ast: "∗", dagger: "†", ddagger: "‡", amalg: "⨿",
  sum: "∑", prod: "∏", coprod: "∐", int: "∫", iint: "∬", oint: "∮", partial: "∂", nabla: "∇", infty: "∞",
  sqrt: "√", surd: "√", wr: "≀", diamond: "⋄", bigcirc: "◯", bigoplus: "⨁", bigotimes: "⨂", bigodot: "⨀",
  // brackets and punctuation
  langle: "⟨", rangle: "⟩", llbracket: "⟦", rrbracket: "⟧", lceil: "⌈", rceil: "⌉", lfloor: "⌊",
  rfloor: "⌋", ulcorner: "⌜", urcorner: "⌝", llcorner: "⌞", lrcorner: "⌟", ldots: "…", cdots: "⋯",
  vdots: "⋮", ddots: "⋱", colon: "∶", prime: "′", dprime: "″", backslash: "\\", S: "§", P: "¶",
  // letters and symbols
  aleph: "ℵ", beth: "ℶ", gimel: "ℷ", hbar: "ℏ", ell: "ℓ", Re: "ℜ", Im: "ℑ", wp: "℘", mho: "℧",
  angle: "∠", measuredangle: "∡", triangle: "△", Box: "□", Diamond: "◇", square: "□", blacksquare: "■",
  checkmark: "✓", flat: "♭", natural: "♮", sharp: "♯", clubsuit: "♣", diamondsuit: "♢", heartsuit: "♡",
  spadesuit: "♠", degree: "°", copyright: "©", pounds: "£", euro: "€", yen: "¥", dots: "…",
  N: "ℕ", Z: "ℤ", Q: "ℚ", R: "ℝ", C: "ℂ", bbN: "ℕ", bbZ: "ℤ", bbQ: "ℚ", bbR: "ℝ", bbC: "ℂ", bbB: "𝔹",
  // subscripts and superscripts: \_0 ₀, \^2 ²
  _0: "₀", _1: "₁", _2: "₂", _3: "₃", _4: "₄", _5: "₅", _6: "₆", _7: "₇", _8: "₈", _9: "₉",
  "_+": "₊", "_-": "₋", "_=": "₌", "_(": "₍", "_)": "₎", _a: "ₐ", _e: "ₑ", _i: "ᵢ", _j: "ⱼ", _o: "ₒ",
  _x: "ₓ", _n: "ₙ", _m: "ₘ", _k: "ₖ", _p: "ₚ", _s: "ₛ", _t: "ₜ",
  "^0": "⁰", "^1": "¹", "^2": "²", "^3": "³", "^4": "⁴", "^5": "⁵", "^6": "⁶", "^7": "⁷", "^8": "⁸",
  "^9": "⁹", "^+": "⁺", "^-": "⁻", "^=": "⁼", "^(": "⁽", "^)": "⁾", "^n": "ⁿ", "^i": "ⁱ",
};

// The `\name` ending at `caret` in `text`: { start, name }, or null
// when no backslash-name ends there. A name is letters, or a
// subscript/superscript mark with one character.
export function texNameBefore(text, caret) {
  const line = text.slice(text.lastIndexOf("\n", caret - 1) + 1, caret);
  const m = /\\([A-Za-z]*|[_^].?)$/.exec(line);
  if (!m) return null;
  return { start: caret - m[0].length, name: m[1] };
}

// What ⌥↵ does at `caret`: { start, end, insert } when one character
// answers (an exact name, or the one name the typed prefix starts);
// { start, end, candidates: [{ name, char }] } when several names start
// with the prefix; null when nothing does.
export function compress(text, caret) {
  const at = texNameBefore(text, caret);
  if (!at) return null;
  const { start, name } = at;
  if (Object.hasOwn(TEX, name)) return { start, end: caret, insert: TEX[name] };
  const candidates = Object.keys(TEX).filter((key) => key.startsWith(name)).map((key) => ({ name: key, char: TEX[key] }));
  if (candidates.length === 0) return null;
  if (candidates.length === 1) return { start, end: caret, insert: candidates[0].char };
  return { start, end: caret, candidates };
}

// Monaco: ⌥↵ compresses at the cursor; several candidates open the
// completion list on them (a provider that answers only then).
export function bindTex(monaco, editor) {
  let pending = null; // { start, end, candidates } for the provider
  monaco.languages.registerCompletionItemProvider("puffin", {
    triggerCharacters: [],
    provideCompletionItems(model, position) {
      if (!pending || model !== editor.getModel()) return { suggestions: [] };
      const { start, end, candidates } = pending;
      pending = null;
      const range = monaco.Range.fromPositions(model.getPositionAt(start), model.getPositionAt(end));
      return {
        suggestions: candidates.map(({ name, char }, i) => ({
          label: `\\${name}  ${char}`,
          kind: monaco.languages.CompletionItemKind.Text,
          detail: "TeX",
          insertText: char,
          filterText: `\\${name}`,
          sortText: String(i).padStart(3, "0"),
          range,
        })),
      };
    },
  });
  editor.onKeyDown((event) => {
    if (!isLambdaKey(event.browserEvent)) return;
    event.preventDefault();
    event.stopPropagation();
    if (editor.getOption(monaco.editor.EditorOption.readOnly)) return;
    editor.pushUndoStop();
    editor.executeEdits("tex", editor.getSelections().map((range) => ({ range, text: "λ", forceMoveMarkers: true })));
    editor.pushUndoStop();
  });
  editor.addAction({
    id: "puffin.tex",
    label: "TeX character (\\lambda → λ)",
    keybindings: [monaco.KeyMod.Alt | monaco.KeyCode.Enter],
    run() {
      const model = editor.getModel();
      if (!model || editor.getOption(monaco.editor.EditorOption.readOnly)) return;
      const caret = model.getOffsetAt(editor.getPosition());
      const result = compress(model.getValue(), caret);
      if (!result) return;
      if (result.candidates) {
        pending = result;
        editor.trigger("tex", "editor.action.triggerSuggest", {});
        return;
      }
      const range = monaco.Range.fromPositions(model.getPositionAt(result.start), model.getPositionAt(result.end));
      editor.pushUndoStop();
      editor.executeEdits("tex", [{ range, text: result.insert }]);
      editor.pushUndoStop();
    },
  });
}

// A plain text field (textarea or input): ⌥↵ compresses at the caret.
// Several candidates take the first; the field has no list to show.
export function bindTexField(field) {
  field.addEventListener("keydown", (event) => {
    if (isLambdaKey(event)) {
      event.preventDefault();
      field.setRangeText("λ", field.selectionStart, field.selectionEnd, "end");
      field.dispatchEvent(new Event("input", { bubbles: true }));
      return;
    }
    if (!(event.altKey && event.key === "Enter")) return;
    const result = compress(field.value, field.selectionStart);
    if (!result) return;
    event.preventDefault();
    event.stopImmediatePropagation(); // before the prompt's own Enter
    const insert = result.insert ?? result.candidates[0].char;
    field.setRangeText(insert, result.start, result.end, "end");
    field.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
