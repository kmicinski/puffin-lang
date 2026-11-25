// How the page says counts and times: "1 edit", "3 edits"; a moment's clock
// time and its day, the same in every panel that shows them.

// `n` and the noun, plural unless n is one: plural(3, "edit") is "3 edits".
export const plural = (n, noun) => `${n} ${noun}${n === 1 ? "" : "s"}`;

// A moment's time of day, to the second, and its date.
export const timeOfDay = (at) => new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
export const dateOf = (at) => new Date(at).toLocaleDateString([], { weekday: "short", year: "numeric", month: "short", day: "numeric" });
