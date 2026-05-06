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
    let state = match state::default_state_file() {
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

/// `cartog self update [--check] [--quiet] [--json]` entry point.
///
/// In `--check` mode this is read-only: it fetches the latest release tag,
/// compares it to the running binary's version, prints a one-line message
/// (or JSON), and exits with one of:
///
/// - `0` — already up to date
/// - `1` — an update is available
/// - `2` — network or parse error
///
/// The non-`--check` path (the actual upgrade) is implemented in a later
/// task and currently bails.
pub fn cmd_self_update(check: bool, quiet: bool, json: bool) -> Result<()> {
    if check {
        let exit_code = run_check(quiet, json);
        std::process::exit(exit_code);
    }
    anyhow::bail!("cartog self update: not yet implemented")
}

/// Drive the read-only `--check` flow and return the desired exit code.
/// Split out so `cmd_self_update` stays readable and the exit-code mapping
/// lives in one place.
fn run_check(quiet: bool, json: bool) -> i32 {
    let api_url = github_latest_url();
    match fetch_latest_version(&api_url) {
        Ok(latest) => {
            let outcome = CheckOutcome::ok(env!("CARGO_PKG_VERSION"), &latest);
            if !quiet {
                emit_check_outcome(&outcome, json);
            }
            if outcome.outdated == Some(true) {
                1
            } else {
                0
            }
        }
        Err(e) => {
            if !quiet {
                let outcome = CheckOutcome::failed(env!("CARGO_PKG_VERSION"), &e.to_string());
                emit_check_outcome(&outcome, json);
            }
            2
        }
    }
}

fn emit_check_outcome(outcome: &CheckOutcome, json: bool) {
    if json {
        // Serialising a flat struct of strings/bools never fails.
        println!(
            "{}",
            serde_json::to_string(outcome).expect("CheckOutcome serialises")
        );
    } else {
        println!("{}", outcome.to_human());
    }
}

pub fn cmd_self_rollback() -> Result<()> {
    anyhow::bail!("cartog self rollback: not yet implemented")
}

// ── --check internals ─────────────────────────────────────────────────

const DEFAULT_GITHUB_LATEST_URL: &str =
    "https://api.github.com/repos/jrollin/cartog/releases/latest";

/// Resolve the GitHub latest-release endpoint. Honors `CARTOG_GITHUB_API_URL`
/// for tests and locked-down environments; falls back to the public default.
fn github_latest_url() -> String {
    std::env::var("CARTOG_GITHUB_API_URL").unwrap_or_else(|_| DEFAULT_GITHUB_LATEST_URL.to_string())
}

/// Fetch the latest stable release tag from GitHub and return it as a bare
/// `MAJOR.MINOR.PATCH` string. Errors out on transport failure, non-2xx
/// status, malformed JSON, or a tag carrying a prerelease suffix.
fn fetch_latest_version(url: &str) -> Result<String> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("cartog/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(5))
        .build()?;
    let response = client
        .get(url)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        // Pin the GitHub REST API version so a future default change does
        // not silently alter response shape (recommended by GitHub docs).
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()?;
    let status = response.status();
    if !status.is_success() {
        anyhow::bail!("GitHub API returned status {status}");
    }
    let body = response.text()?;
    parse_release_tag(&body).ok_or_else(|| {
        anyhow::anyhow!("could not extract a stable release tag from GitHub response")
    })
}

/// Pull `tag_name` out of the GitHub release JSON, strip a leading `v`, and
/// return `None` for any prerelease-shaped tag. SemVer prerelease metadata
/// is delimited by `-`, so any hyphen in the version (e.g. `0.15.0-rc.1`,
/// `0.15.0-alpha`, `0.15.0-nightly.42`) disqualifies the tag.
fn parse_release_tag(json: &str) -> Option<String> {
    let parsed: serde_json::Value = serde_json::from_str(json).ok()?;
    let tag = parsed.get("tag_name")?.as_str()?;
    let trimmed = tag.strip_prefix('v').unwrap_or(tag);
    if trimmed.contains('-') {
        return None;
    }
    if !is_stable_semver(trimmed) {
        return None;
    }
    Some(trimmed.to_string())
}

/// Quick guard: accept exactly three dot-separated non-empty numeric parts.
fn is_stable_semver(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// JSON-friendly view of an update check. A single shape covers both the
/// success and failure cases so consumers don't have to switch on schema:
/// on failure, `latest` and `outdated` are `null` and `error` is set.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
struct CheckOutcome {
    current: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    latest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    outdated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl CheckOutcome {
    fn ok(current: &str, latest: &str) -> Self {
        let outdated = compare_stable_versions(current, latest) == std::cmp::Ordering::Less;
        Self {
            current: current.to_string(),
            latest: Some(latest.to_string()),
            outdated: Some(outdated),
            error: None,
        }
    }

    fn failed(current: &str, error: &str) -> Self {
        Self {
            current: current.to_string(),
            latest: None,
            outdated: None,
            error: Some(error.to_string()),
        }
    }

    fn to_human(&self) -> String {
        match (&self.latest, self.outdated, &self.error) {
            (Some(latest), Some(true), _) => {
                format!(
                    "cartog: update available: {current} -> {latest}",
                    current = self.current,
                    latest = latest,
                )
            }
            (_, Some(false), _) => format!("cartog: up to date ({})", self.current),
            (_, _, Some(err)) => format!("cartog: update check failed: {err}"),
            // Unreachable in practice — every outcome is built via `ok` or `failed`.
            _ => "cartog: update check produced an empty outcome".to_string(),
        }
    }
}

/// Lexicographic compare on `(major, minor, patch)`.
///
/// Both inputs are expected to be stable `MAJOR.MINOR.PATCH` triples — any
/// non-numeric component is treated as `0`, so the function never panics on
/// weird input but degrades gracefully.
fn compare_stable_versions(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |s: &str| -> [u64; 3] {
        let mut parts = s.split('.').map(|p| p.parse::<u64>().unwrap_or(0));
        [
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
        ]
    };
    parse(a).cmp(&parse(b))
}
