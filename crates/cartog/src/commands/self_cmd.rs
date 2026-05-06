//! Implementations for the `cartog self` subcommand group.
//!
//! Pure logic is factored into helpers (`resolve_install_source`,
//! `VersionInfo`) that take their inputs as arguments so integration tests
//! can drive them without touching the real environment, filesystem, or
//! network. The thin `cmd_self_*` wrappers gather the real-world inputs and
//! delegate to the pure helpers.

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::Serialize;

use crate::state::{self, State};

/// Compile-time channel as written by `build.rs`. One of:
/// - `"release-tarball"` — built by the GitHub release workflow.
/// - `"dev"` — every other build (local `cargo build`, `cargo install`, …).
const COMPILE_TIME_INSTALL_SOURCE: &str = env!("CARTOG_INSTALL_SOURCE");

/// Compile-time target triple, e.g. `aarch64-apple-darwin`.
const TARGET_TRIPLE: &str = env!("CARTOG_TARGET_TRIPLE");

/// Resolve the *effective* install source.
///
/// `build.rs` only distinguishes `release-tarball` from `dev` because it has
/// no idea where the resulting binary will be installed. The cargo case is
/// detected at runtime: if the compile-time channel is `dev` AND the running
/// binary lives under a `.cargo/bin` directory, the user almost certainly
/// ran `cargo install cartog`.
///
/// `binary_path` is taken as an argument so tests can drive every branch.
pub(crate) fn resolve_install_source(
    compile_time: &str,
    binary_path: Option<&Path>,
    cargo_home: Option<&Path>,
) -> &'static str {
    if compile_time == "release-tarball" {
        return "release-tarball";
    }
    if let Some(bin) = binary_path {
        if looks_like_cargo_install(bin, cargo_home) {
            return "cargo";
        }
    }
    "dev"
}

fn looks_like_cargo_install(binary_path: &Path, cargo_home: Option<&Path>) -> bool {
    // Honor an explicit CARGO_HOME first.
    if let Some(home) = cargo_home {
        let bin_dir = home.join("bin");
        if binary_path.starts_with(&bin_dir) {
            return true;
        }
    }
    // Fallback: detect a `.cargo/bin/<name>` segment anywhere in the path.
    // This catches the standard `~/.cargo/bin` install location even when
    // CARGO_HOME isn't set in the running shell (common on macOS).
    let mut prev: Option<&std::ffi::OsStr> = None;
    for component in binary_path.components() {
        let cur = component.as_os_str();
        if prev == Some(std::ffi::OsStr::new(".cargo")) && cur == std::ffi::OsStr::new("bin") {
            return true;
        }
        prev = Some(cur);
    }
    false
}

/// Snapshot of "what version of cartog am I, and how did I get here?".
#[derive(Debug, Clone, Serialize)]
pub(crate) struct VersionInfo {
    pub version: String,
    pub target: String,
    pub install_source: String,
    /// RFC3339 timestamp of the last successful update check, or `None`.
    /// Serialised as JSON `null` when absent.
    pub last_update_check: Option<String>,
}

impl VersionInfo {
    pub(crate) fn build(state: &State, binary_path: Option<&Path>) -> Self {
        let cargo_home = std::env::var_os("CARGO_HOME").map(PathBuf::from);
        let install_source = resolve_install_source(
            COMPILE_TIME_INSTALL_SOURCE,
            binary_path,
            cargo_home.as_deref(),
        );
        Self {
            version: env!("CARGO_PKG_VERSION").to_string(),
            target: TARGET_TRIPLE.to_string(),
            install_source: install_source.to_string(),
            last_update_check: state.last_update_check.clone(),
        }
    }

    /// Render the human-readable form printed when `--json` is not set.
    pub(crate) fn render_human(&self) -> String {
        let last = self.last_update_check.as_deref().unwrap_or("never");
        format!(
            "cartog {version}\n  target:           {target}\n  install source:   {source}\n  last update check: {last}\n",
            version = self.version,
            target = self.target,
            source = self.install_source,
            last = last,
        )
    }
}

/// `cartog self version` entry point. Reads the on-disk state file and the
/// running binary's path, then prints either a human-readable summary or a
/// JSON object.
pub fn cmd_self_version(json: bool) -> Result<()> {
    let state = match state::default_path() {
        Some(p) => State::load_from(&p),
        None => State::default(),
    };
    let binary_path = std::env::current_exe().ok();
    let info = VersionInfo::build(&state, binary_path.as_deref());
    if json {
        println!("{}", serde_json::to_string_pretty(&info)?);
    } else {
        print!("{}", info.render_human());
    }
    Ok(())
}

pub fn cmd_self_update(_check: bool, _quiet: bool, _json: bool) -> Result<()> {
    anyhow::bail!("cartog self update: not yet implemented")
}

pub fn cmd_self_rollback() -> Result<()> {
    anyhow::bail!("cartog self rollback: not yet implemented")
}
