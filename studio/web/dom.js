// Building the page's elements. Every panel makes its rows, chips and
// buttons the same few ways; they are written once here.

// An element with a class and, if given, its text (never markup).
export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
