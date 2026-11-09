//! `puffin-studio [PROJECT_DIR] [--port N] [--no-open]`: serve Puffin Studio
//! for the project in PROJECT_DIR (default: the current directory) on
//! 127.0.0.1, and print the address to open.

use puffin_studio::{private_token, project, repository_root, studio::Studio, web};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "usage: puffin-studio [PROJECT_DIR] [--port N] [--no-open]

Edit, check and evaluate the Puffin files of PROJECT_DIR (default: the
current directory) in the browser. The studio listens on 127.0.0.1:N
(default 7360) and opens http://127.0.0.1:N.
--no-open    print the address without opening a browser
--new [NAME] make a project under the projects home (PUFFIN_PROJECTS,
             else ~/Puffin; NAME, or a short random one) and serve it

A project is a git repository (made one when opened, unless it sits inside
another repository): edits are saved and committed as they settle, and
evaluations, questions and test runs are journaled with them
(.puffin/journal.jsonl). History in the studio shows it all.

PUFFIN_ROOT names the Puffin repository (default: the one this binary was
built in); PUFFIN_STUDIO_PUFFINCC and PUFFIN_STUDIO_VM name the compiler and
VM (default build/puffincc and bin/puffin-vm there). The assistant runs
`claude -p`; PUFFIN_STUDIO_MODEL and PUFFIN_STUDIO_EFFORT pick its model and
effort.";

struct Options {
    directory: Option<PathBuf>,
    port: u16,
    open: bool,
    /// --new: make a project (Some(None): with a random name).
    new: Option<Option<String>>,
}

fn options(args: impl IntoIterator<Item = String>) -> Result<Option<Options>, String> {
    let mut options = Options { directory: None, port: 7360, open: true, new: None };
    let mut args = args.into_iter().peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => options.port = args.next().and_then(|port| port.parse().ok()).ok_or("--port needs a port number")?,
            "--no-open" => options.open = false,
            "--new" => options.new = Some(args.next_if(|next| !next.starts_with('-'))),
            "-h" | "--help" => return Ok(None),
            flag if flag.starts_with('-') => return Err(format!("unknown option {flag}\n{USAGE}")),
            directory if options.directory.is_none() => options.directory = Some(PathBuf::from(directory)),
            _ => return Err(USAGE.to_owned()),
        }
    }
    Ok(Some(options))
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("puffin-studio: {message}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let Some(options) = options(std::env::args().skip(1))? else {
        println!("{USAGE}");
        return Ok(());
    };
    let directory = match (&options.new, options.directory) {
        (Some(name), _) => project::create(&project::home(), name.as_deref())?,
        (None, directory) => directory.unwrap_or_else(|| PathBuf::from(".")),
    };
    let directory = std::fs::canonicalize(&directory).map_err(|error| format!("{}: {error}", directory.display()))?;
    if !directory.is_dir() {
        return Err(format!("{} is not a directory", directory.display()));
    }
    let adopted = project::adopt(&directory);
    let root = repository_root();
    let mcp_token = private_token().map_err(|error| format!("cannot make a token: {error}"))?;
    let studio = Studio::new(root.clone(), directory.clone(), mcp_token.clone()).map_err(|error| error.to_string())?;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", options.port))
        .await
        .map_err(|error| format!("cannot listen on 127.0.0.1:{}: {error}", options.port))?;
    let port = listener.local_addr().map_err(|error| error.to_string())?.port();
    studio.set_port(port);
    studio.start();
    let url = format!("http://127.0.0.1:{port}/");
    println!("Puffin Studio: {}", directory.display());
    println!("  {url}");
    match adopted {
        Ok(true) => println!("  history: committed to the project's git repository as you work"),
        Ok(false) => println!("  note: {} sits inside another repository, so its history is not committed", directory.display()),
        Err(error) => println!("  warning: the project is not tracked: {error}"),
    }
    for (what, path) in [("compiler", &studio.toolchain.puffincc), ("VM", &studio.toolchain.vm)] {
        if !path.is_file() {
            println!("  warning: no {what} at {} (bin/bootstrap builds it)", path.display());
        }
    }
    if !root.join("web/node_modules/monaco-editor/min/vs/loader.js").is_file() {
        println!("  note: Monaco is not installed; the editor is a plain textarea. (cd web && npm install) for the full editor.");
    }
    if options.open {
        let _ = std::process::Command::new("open").arg(&url).spawn();
    }
    let web = web::Web::new(studio, root, mcp_token);
    let app = web::router(web.clone());
    // Ctrl-C or SIGTERM: stop, and take the scratch directory along
    let shutdown = async {
        let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = async { if let Some(t) = terminate.as_mut() { t.recv().await; } else { std::future::pending::<()>().await } } => {}
        }
    };
    let served = axum::serve(listener, app).with_graceful_shutdown(shutdown).await;
    // the last edits and records land before the studio goes
    let studio = web.current();
    studio.flush_journal().await;
    let _ = std::fs::remove_dir_all(&studio.toolchain.scratch);
    served.map_err(|error| error.to_string())
}
