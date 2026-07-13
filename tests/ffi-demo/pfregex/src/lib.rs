// pfregex -- the Rust guest of docs/FFI.md §9.4: the regex crate
// behind a C ABI, imported into Puffin as a typed foreign library.
//
// The §9.2 disciplines, all present:
//   - only C types cross (raw pointers, i64, bool);
//   - handles are born Box::into_raw and die Box::from_raw in exactly
//     one export (pfregex_free, the #:consumes target) -- Puffin's
//     null-on-close guarantees that runs at most once;
//   - strings out are CString::into_raw paired with pfregex_str_free
//     (the #:gift function) -- NEVER libc free across allocators;
//   - strings in arrive borrowed; to_owned/UTF-8-validate before any
//     retention; invalid UTF-8 answers the declared error idiom
//     (NULL / false), never a panic;
//   - panic = "abort" in the release profile (Cargo.toml).

use regex::Regex;
use std::ffi::{c_char, CStr, CString};

fn borrow_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// (: regex-compile (-> Str (Nullable Regex))): NULL on a bad pattern.
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_compile(pattern: *const c_char) -> *mut Regex {
    match borrow_str(pattern).and_then(|s| Regex::new(s).ok()) {
        Some(re) => Box::into_raw(Box::new(re)),
        None => std::ptr::null_mut(),
    }
}

/// (: regex-match? (-> Regex Str Bool))
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_is_match(re: *const Regex, hay: *const c_char) -> bool {
    match (unsafe { re.as_ref() }, borrow_str(hay)) {
        (Some(re), Some(hay)) => re.is_match(hay),
        _ => false,
    }
}

/// (: regex-find (-> Regex Str (Nullable Str)) #:gift "pfregex_str_free"):
/// the first match, malloc'd by Rust's allocator and gifted back.
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_find(re: *const Regex, hay: *const c_char) -> *mut c_char {
    let found = match (unsafe { re.as_ref() }, borrow_str(hay)) {
        (Some(re), Some(hay)) => re.find(hay).map(|m| m.as_str().to_owned()),
        _ => None,
    };
    match found.and_then(|s| CString::new(s).ok()) {
        Some(c) => c.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// (: regex-count (-> Regex Str Int))
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_count(re: *const Regex, hay: *const c_char) -> i64 {
    match (unsafe { re.as_ref() }, borrow_str(hay)) {
        (Some(re), Some(hay)) => re.find_iter(hay).count() as i64,
        _ => 0,
    }
}

/// the #:gift deallocator: Rust's allocator frees Rust's memory
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_str_free(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) });
    }
}

/// (: regex-close (-> Regex Void) #:c-name "pfregex_free" #:consumes)
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_free(re: *mut Regex) {
    if !re.is_null() {
        drop(unsafe { Box::from_raw(re) });
    }
}
