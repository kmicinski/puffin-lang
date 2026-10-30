//! What the assistant can read about Puffin: the repository's docs/*.md
//! and the example programs, through the `search_docs` and `read_doc`
//! tools. The language reference (docs/LANGUAGE.md) also leads the system
//! prompt.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The files the tools may read, relative to the repository root.
pub fn corpus(root: &Path) -> Vec<PathBuf> {
    let mut files = listing(root, Path::new("docs"), &["md"], false);
    files.extend(listing(root, Path::new("examples"), &["puf", "md"], true));
    files.retain(|file| root.join(file).is_file());
    files
}

fn listing(root: &Path, directory: &Path, extensions: &[&str], recurse: bool) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root.join(directory)) else { return Vec::new() };
    let mut out = Vec::new();
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let relative = directory.join(entry.file_name());
        let path = entry.path();
        if path.is_dir() {
            if recurse {
                out.extend(listing(root, &relative, extensions, true));
            }
        } else if path.extension().and_then(|e| e.to_str()).is_some_and(|e| extensions.contains(&e)) {
            out.push(relative);
        }
    }
    out
}

/// The language reference the system prompt carries.
pub fn reference(root: &Path) -> String {
    std::fs::read_to_string(root.join("docs/LANGUAGE.md")).unwrap_or_default()
}

/// The paragraphs best matching `query`'s words, with file and line.
pub fn search(root: &Path, query: &str, limit: usize) -> Value {
    let query = query.to_lowercase();
    let terms: Vec<&str> = query.split_whitespace().collect();
    let mut hits = Vec::new();
    for file in corpus(root) {
        let Ok(text) = std::fs::read_to_string(root.join(&file)) else { continue };
        let lines: Vec<&str> = text.lines().collect();
        let mut heading = "";
        let mut start = 0;
        while start < lines.len() {
            if lines[start].trim().is_empty() {
                start += 1;
                continue;
            }
            let end = (start..lines.len()).find(|&i| lines[i].trim().is_empty()).unwrap_or(lines.len());
            let paragraph = lines[start..end].join("\n");
            let lower = paragraph.to_lowercase();
            let matched = terms.iter().filter(|term| lower.contains(*term)).count();
            if matched > 0 {
                let phrase = lower.contains(query.trim());
                let count: usize = terms.iter().map(|term| lower.matches(term).count()).sum();
                let language = file.ends_with("LANGUAGE.md") || file.ends_with("STDLIB.md") || file.ends_with("TYPES.md");
                hits.push(((matched, phrase, language, count), file.clone(), start + 1, heading.to_owned(), paragraph));
            }
            if let Some(line) = lines[start..end].iter().rev().find(|line| line.starts_with('#')) {
                heading = line;
            }
            start = end;
        }
    }
    hits.sort_by(|a, b| b.0.cmp(&a.0));
    let results: Vec<Value> = hits
        .into_iter()
        .take(limit)
        .map(|(_, file, line, heading, paragraph)| {
            let text: Vec<&str> = paragraph.lines().take(16).collect();
            json!({ "path": file, "line": line, "section": heading, "text": text.join("\n") })
        })
        .collect();
    json!({ "results": results })
}

/// Lines of one corpus file, numbered from `start` (1-based).
pub fn read(root: &Path, path: &str, start: usize, count: usize) -> Result<Value, String> {
    let wanted = Path::new(path.trim_start_matches("./"));
    if !corpus(root).iter().any(|file| file == wanted) {
        return Err(format!("{path} is not readable: read_doc opens docs/*.md and examples/; search_docs names them"));
    }
    let text = std::fs::read_to_string(root.join(wanted)).map_err(|error| format!("cannot read {path}: {error}"))?;
    let lines: Vec<&str> = text.lines().collect();
    let first = start.max(1);
    let last = (first + count.clamp(1, 400) - 1).min(lines.len());
    let numbered: Vec<String> = (first..=last).map(|n| format!("{n:5}  {}", lines[n - 1])).collect();
    Ok(json!({ "path": path, "lines": format!("{first}-{last} of {}", lines.len()), "text": numbered.join("\n") }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
    }

    #[test]
    fn the_docs_are_searchable_and_readable() {
        let found = search(&root(), "define-type match", 3);
        assert!(!found["results"].as_array().unwrap().is_empty());
        let read = read(&root(), "docs/LANGUAGE.md", 1, 3).unwrap();
        assert!(read["text"].as_str().unwrap().contains("The Puffin Language"));
        assert!(super::read(&root(), "../etc/passwd", 1, 3).is_err());
        assert!(super::read(&root(), "src/main.rkt", 1, 3).is_err());
    }
}
