//! Puffin Studio: a local web workbench for Puffin programs -- an editor
//! over the program's modules, a REPL transcript backed by a live VM
//! session, compiler-driven assists, and an assistant one key away
//! (docs/STUDIO.md). The semantics all live in puffincc; this is the
//! server that drives it and the page that shows it.

pub mod agent;
pub mod ask;
pub mod knowledge;
pub mod lane;
pub mod mcp;
pub mod repl;
pub mod review;
pub mod sexp;
pub mod studio;
pub mod toolchain;
pub mod versions;
pub mod web;

#[cfg(test)]
mod tests;

use std::io::Read;
use std::path::{Path, PathBuf};

/// 32 random bytes as hex: the launch token and the MCP bearer token.
pub fn private_token() -> std::io::Result<String> {
    let mut random = [0_u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// The Puffin repository: PUFFIN_ROOT, else the one this crate was built
/// in (studio/ is its top-level directory).
pub fn repository_root() -> PathBuf {
    if let Some(root) = std::env::var_os("PUFFIN_ROOT") {
        return PathBuf::from(root);
    }
    let built = Path::new(env!("CARGO_MANIFEST_DIR")).parent().map(Path::to_path_buf).unwrap_or_default();
    std::fs::canonicalize(&built).unwrap_or(built)
}

/// The token that admits a browser tab, kept (readable only by this user)
/// in PUFFIN_STUDIO_HOME (default ~/.puffin-studio) and reused, so a
/// restarted studio keeps its address and an open tab simply reconnects.
pub fn launch_token() -> std::io::Result<String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let home = std::env::var_os("PUFFIN_STUDIO_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".puffin-studio")));
    let Some(home) = home else { return private_token() };
    std::fs::create_dir_all(&home)?;
    let path = home.join("token");
    if let Ok(token) = std::fs::read_to_string(&path)
        && token.len() == 64
        && token.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Ok(token);
    }
    let token = private_token()?;
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?
        .write_all(token.as_bytes())?;
    Ok(token)
}
