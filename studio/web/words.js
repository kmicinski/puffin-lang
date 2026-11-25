// How the page says what more than one panel says: counts ("1 edit",
// "3 edits"), a moment's time of day and its date, and the voice builder's runs.

// `n` and the noun, plural unless n is one: plural(3, "edit") is "3 edits".
export const plural = (n, noun) => `${n} ${noun}${n === 1 ? "" : "s"}`;

// A moment's time of day, to the second, and its date.
export const timeOfDay = (at) => new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
export const dateOf = (at) => new Date(at).toLocaleDateString([], { weekday: "short", year: "numeric", month: "short", day: "numeric" });

// ---- The voice builder's runs (timeline.js, progress.js) ----------------

// What a run was asked to do, in a line: the first line of each
// instruction, or what the studio's own automatic retry is for.
export function turnLabel(instructions = []) {
  if (instructions.length === 1 && instructions[0].startsWith("(Automatic")) return "fixing the failing properties";
  return instructions.map((i) => i.split("\n")[0]).join(" · ") || "working";
}

// How a run ended, in a word.
export const outcomeWord = (outcome) =>
  ({ done: "done", interrupted: "redirected", stopped: "stopped", failed: "failed" })[outcome] ?? outcome;
