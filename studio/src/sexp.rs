//! Puffin text as top-level forms, found the way puffincc's reader finds
//! them (`puffincc-src/reader.puf`): `;` comments to the end of the line,
//! strings with backslash escapes, `(` `[` lists, and the quote prefixes.
//!
//! This is structure only, for the studio's own bookkeeping: which form
//! the cursor is in, which `define-type` forms a REPL unit carries, which
//! files a module requires. The compiler is the only source of meaning.
//! The scan tolerates unbalanced text: a list missing its closer runs to
//! the end.
//!
//! Positions are byte offsets.

/// One top-level form.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Form {
    pub start: usize,
    pub end: usize,
    /// 1-based line of its first byte.
    pub line: usize,
    /// The first symbol inside a list form: `define`, `define-type`, ...
    pub head: Option<String>,
    /// What the form defines: `f` of `(define (f x) ...)`, `Expr` of
    /// `(define-type Expr ...)` or `(define-type (Option a) ...)`.
    pub name: Option<String>,
    /// The first string inside the form: a `require`'s path.
    pub string: Option<String>,
    /// Its place among the top-level forms, from 0.
    pub index: usize,
}

impl Form {
    /// The form's key, as `--assist forms` names forms: `define:eval-expr`,
    /// `define-type:Expr`, `sig:f` for `(: f τ)`, `require:vec.puf`, or
    /// `expr:INDEX` for anything else.
    pub fn key(&self) -> String {
        match (self.head.as_deref(), &self.name, &self.string) {
            (Some(":"), Some(name), _) => format!("sig:{name}"),
            (Some("require"), _, Some(path)) => format!("require:{path}"),
            (Some(head), Some(name), _) if head.starts_with("define") => format!("{head}:{name}"),
            _ => format!("expr:{}", self.index),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Token {
    Open,
    Close,
    /// A string literal; its bytes are `start + 1 .. end - 1`.
    Str,
    /// `'`, `` ` ``, `,` or `,@`.
    Prefix,
    Atom,
    Comment,
}

fn delimiter(byte: u8) -> bool {
    byte.is_ascii_whitespace() || matches!(byte, b'(' | b')' | b'[' | b']' | b'"' | b';')
}

/// Every token of `text` with its byte span.
fn tokens(text: &str) -> Vec<(Token, usize, usize)> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let start = i;
        let byte = bytes[i];
        let kind = match byte {
            _ if byte.is_ascii_whitespace() => {
                i += 1;
                continue;
            }
            b';' => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                Token::Comment
            }
            b'(' | b'[' => {
                i += 1;
                Token::Open
            }
            b')' | b']' => {
                i += 1;
                Token::Close
            }
            b'"' => {
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    i += if bytes[i] == b'\\' { 2 } else { 1 };
                }
                i = (i + 1).min(bytes.len());
                Token::Str
            }
            b'\'' | b'`' => {
                i += 1;
                Token::Prefix
            }
            b',' => {
                i += if bytes.get(i + 1) == Some(&b'@') { 2 } else { 1 };
                Token::Prefix
            }
            _ => {
                while i < bytes.len() && !delimiter(bytes[i]) {
                    i += 1;
                }
                Token::Atom
            }
        };
        out.push((kind, start, i));
    }
    out
}

/// The top-level forms of `text`, in order. A stray closer at the top level
/// is skipped.
pub fn forms(text: &str) -> Vec<Form> {
    let line_of = |at: usize| text[..at].bytes().filter(|&b| b == b'\n').count() + 1;
    let mut found = Vec::new();
    let mut depth = 0usize;
    // the form being read: its start, and the atoms and strings seen at
    // depth 1 and 2 (for the head and name)
    let mut current: Option<Form> = None;
    // a prefix at the top level starts the form it applies to
    let mut prefix: Option<usize> = None;
    // the child index at depth 1, and whether the second child is a list
    let mut child = 0usize;
    let mut name_list = false;
    for (kind, start, end) in tokens(text) {
        let word = &text[start..end];
        match kind {
            Token::Comment => continue,
            Token::Prefix => {
                if depth == 0 && prefix.is_none() {
                    prefix = Some(start);
                }
                continue;
            }
            Token::Open => {
                if depth == 0 {
                    let at = prefix.take().unwrap_or(start);
                    current = Some(Form { start: at, end: text.len(), line: line_of(at), head: None, name: None, string: None, index: found.len() });
                    child = 0;
                    name_list = false;
                } else if depth == 1 {
                    child += 1;
                    name_list = child == 2;
                }
                depth += 1;
            }
            Token::Close => {
                if depth == 0 {
                    continue;
                }
                depth -= 1;
                if depth == 1 {
                    name_list = false;
                }
                if depth == 0
                    && let Some(mut form) = current.take()
                {
                    form.end = end;
                    found.push(form);
                }
            }
            Token::Atom | Token::Str => {
                if depth == 0 {
                    let at = prefix.take().unwrap_or(start);
                    found.push(Form { start: at, end, line: line_of(at), head: None, name: None, string: None, index: found.len() });
                    continue;
                }
                let Some(form) = current.as_mut() else { continue };
                if kind == Token::Str && form.string.is_none() {
                    form.string = Some(unescape(&text[start + 1..end.saturating_sub(1).max(start + 1)]));
                }
                if depth == 1 {
                    child += 1;
                    match child {
                        1 if kind == Token::Atom => form.head = Some(word.to_owned()),
                        2 if kind == Token::Atom => form.name = Some(word.to_owned()),
                        _ => {}
                    }
                } else if depth == 2 && name_list && form.name.is_none() && kind == Token::Atom {
                    form.name = Some(word.to_owned());
                }
            }
        }
    }
    if let Some(form) = current {
        found.push(form);
    }
    found
}

fn unescape(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => out.push(other),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// The top-level form holding byte `pos`: the one it is inside or just
/// after the end of, else the one starting next on the same line.
pub fn form_at(text: &str, pos: usize) -> Option<Form> {
    let all = forms(text);
    if let Some(form) = all.iter().find(|form| form.start <= pos && pos <= form.end) {
        return Some(form.clone());
    }
    let line_end = text[pos.min(text.len())..].find('\n').map_or(text.len(), |at| pos + at);
    all.into_iter().find(|form| form.start >= pos && form.start < line_end)
}

/// The `define-type` forms of `text`: (type name, form text).
pub fn define_types(text: &str) -> Vec<(String, String)> {
    forms(text)
        .into_iter()
        .filter(|form| form.head.as_deref() == Some("define-type"))
        .filter_map(|form| Some((form.name.clone()?, text[form.start..form.end].to_owned())))
        .collect()
}

/// The paths `(require "path" ...)` forms name, as written.
pub fn requires(text: &str) -> Vec<String> {
    forms(text)
        .into_iter()
        .filter(|form| form.head.as_deref() == Some("require"))
        .filter_map(|form| form.string)
        .collect()
}

/// Whether the brackets of `text` balance, outside strings and comments,
/// and every string closes.
pub fn balanced(text: &str) -> bool {
    let mut depth: i64 = 0;
    for (kind, start, end) in tokens(text) {
        match kind {
            Token::Open => depth += 1,
            Token::Close => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            Token::Str => {
                let closed = end - start >= 2 && text.as_bytes()[end - 1] == b'"' && !escaped_end(&text[start..end]);
                if !closed {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

/// Whether a string token's last quote is escaped (so it never closed).
fn escaped_end(token: &str) -> bool {
    let bytes = token.as_bytes();
    let mut i = 1;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b'"' => return i != bytes.len() - 1,
            _ => i += 1,
        }
    }
    true
}

// ---- Offsets ---------------------------------------------------------------

/// The byte offset of UTF-16 offset `units` into `text` (what Monaco
/// counts), clamped to the text.
pub fn byte_of_utf16(text: &str, units: usize) -> usize {
    let mut seen = 0;
    for (at, c) in text.char_indices() {
        if seen >= units {
            return at;
        }
        seen += c.len_utf16();
    }
    text.len()
}

/// The UTF-16 offset of byte offset `byte` into `text`, clamped; a byte
/// inside a character counts as that character's start.
pub fn utf16_of_byte(text: &str, byte: usize) -> usize {
    let mut units = 0;
    for (at, c) in text.char_indices() {
        if at >= byte {
            return units;
        }
        units += c.len_utf16();
    }
    units
}

/// 1-based line of byte offset `at`.
pub fn line_of(text: &str, at: usize) -> usize {
    text.as_bytes()[..at.min(text.len())].iter().filter(|&&b| b == b'\n').count() + 1
}

/// The byte offset of 1-based `line` and `column` (in characters).
pub fn offset_of(text: &str, line: usize, column: usize) -> usize {
    let mut start = 0;
    for _ in 1..line.max(1) {
        match text[start..].find('\n') {
            Some(at) => start += at + 1,
            None => return text.len(),
        }
    }
    let end = text[start..].find('\n').map_or(text.len(), |at| start + at);
    text[start..end].char_indices().nth(column.saturating_sub(1)).map_or(end, |(at, _)| start + at)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROGRAM: &str = "\
(require \"vec.puf\" #:as V)
;; a comment (with a paren
(define-type Expr
  (Num Int)
  (Add Expr Expr))
(define-type (Option a) (None) (Some a))
(define (eval-expr [e : Expr]) : Int
  (match e
    [(Num n) n]
    [(Add a b) (+ (eval-expr a) (eval-expr b))]))
(define scale \"a ) string\")
'(quoted list)
42
";

    #[test]
    fn forms_have_spans_heads_and_names() {
        let found = forms(PROGRAM);
        let keys: Vec<String> = found.iter().map(Form::key).collect();
        assert_eq!(
            keys,
            ["require:vec.puf", "define-type:Expr", "define-type:Option", "define:eval-expr", "define:scale", "expr:5", "expr:6"]
        );
        assert_eq!(found[0].head.as_deref(), Some("require"));
        assert_eq!(found[0].string.as_deref(), Some("vec.puf"));
        let eval = &found[3];
        assert!(PROGRAM[eval.start..eval.end].starts_with("(define (eval-expr"));
        assert!(PROGRAM[eval.start..eval.end].ends_with("(eval-expr b))]))"));
        assert_eq!(eval.line, 7);
        assert_eq!(&PROGRAM[found[5].start..found[5].end], "'(quoted list)");
    }

    #[test]
    fn define_types_and_requires() {
        let types = define_types(PROGRAM);
        assert_eq!(types.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>(), ["Expr", "Option"]);
        assert_eq!(types[1].1, "(define-type (Option a) (None) (Some a))");
        assert_eq!(requires(PROGRAM), ["vec.puf"]);
    }

    #[test]
    fn the_form_at_a_point() {
        let at = PROGRAM.find("(+ (eval-expr a)").unwrap();
        assert_eq!(form_at(PROGRAM, at).unwrap().key(), "define:eval-expr");
        // just after a form's closer is still that form
        let end = forms(PROGRAM)[4].end;
        assert_eq!(form_at(PROGRAM, end).unwrap().key(), "define:scale");
    }

    #[test]
    fn unbalanced_text_still_scans() {
        let found = forms("(define (f x)\n  (+ x 1)\n(define y 2)");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].end, "(define (f x)\n  (+ x 1)\n(define y 2)".len());
        assert!(!balanced("(f 1"));
        assert!(!balanced("(f \"1)"));
        assert!(!balanced("(f \"a\\\")"));
        assert!(balanced("(f \"a\\\"\" [x]) ; (("));
        assert!(!balanced("(f))"));
    }

    #[test]
    fn offsets_convert_between_utf16_and_bytes() {
        let text = "(λ (x) \"é😀\" x)";
        let smile = text.find('😀').unwrap();
        let units = utf16_of_byte(text, smile);
        assert_eq!(units, 9);
        assert_eq!(byte_of_utf16(text, units), smile);
        assert_eq!(byte_of_utf16(text, units + 2), smile + 4);
        assert_eq!(utf16_of_byte(text, text.len()), text.encode_utf16().count());
        assert_eq!(offset_of("ab\ncd\n", 2, 2), 4);
        assert_eq!(line_of("ab\ncd\n", 4), 2);
    }
}
