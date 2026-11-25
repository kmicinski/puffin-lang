// The small things every panel does the same way: build its elements
// (a row, a button, a field for a name) and wait for typing to pause.

// An element with a class and, if given, its text (never markup).
export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// A button: what it says, what a click on it does, and -- if given -- what
// hovering over it says.
export function button(className, text, onClick, title) {
  const node = el("button", className, text);
  if (onClick) node.addEventListener("click", onClick);
  if (title) node.title = title;
  return node;
}

// A field for typing a name, a path or a filter: the browser neither
// spell-checks it nor offers to fill it in, since neither knows Puffin.
export function nameField(className, placeholder = "") {
  const node = el("input", className);
  node.placeholder = placeholder;
  node.spellcheck = false;
  node.autocomplete = "off";
  return node;
}

// `fn`, run once calls to the function returned pause for `ms`: a burst of
// keystrokes or events refreshes once, after it.
export function debounce(fn, ms) {
  let timer = 0;
  return () => {
    clearTimeout(timer);
    timer = setTimeout(fn, ms);
  };
}
