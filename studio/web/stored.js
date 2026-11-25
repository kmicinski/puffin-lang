// What this browser remembers between visits (localStorage): the prompt's
// history, the assistant's scope, which panels were open. A private window
// may refuse the storage; then the studio only forgets, it never fails.

export function recall(key, fallback = null) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}

// A value stored as JSON; `fallback` when it is missing or unreadable.
export function recallJSON(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
}

// `value` under `key` (a string, or anything as JSON with `json`); null forgets it.
export function remember(key, value, { json = false } = {}) {
  try {
    if (value === null || value === undefined) localStorage.removeItem(key);
    else localStorage.setItem(key, json ? JSON.stringify(value) : value);
  } catch { /* a private window: forgotten */ }
}
