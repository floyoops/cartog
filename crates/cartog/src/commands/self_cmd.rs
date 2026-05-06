//! Implementations for the `cartog self` subcommand group.
//!
//! Pure logic is factored into helpers (`resolve_install_source`,
//! `VersionInfo`) that take their inputs as arguments so integration tests
//! can drive them without touching the real environment, filesystem, or
//! network. The thin `cmd_self_*` wrappers gather the real-world inputs and
//! delegate to the pure helpers.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Result;
use serde::Serialize;

use crate::state::{self, State};
use cartog::time_fmt::rfc3339_now;

/// Compile-time channel as written by `build.rs`. One of:
/// - `"release-tarball"` — built by the GitHub release workflow.
/// - `"dev"` — every other build (local `cargo build`, `cargo install`, …).
const COMPILE_TIME_INSTALL_SOURCE: &str = env!("CARTOG_INSTALL_SOURCE");

/// Compile-time target triple, e.g. `aarch64-apple-darwin`.
const TARGET_TRIPLE: &str = env!("CARTOG_TARGET_TRIPLE");

/// Test seam: when set to `release-tarball`, `cargo`, or `dev`, the install
/// source is forced to that value, bypassing the compile-time + path
/// heuristics. Lets the integration suite drive the cargo-refusal branch
/// without producing a real cargo install. Read only by `effective_install_source`.
const TEST_INSTALL_SOURCE_ENV: &str = "CARTOG_TEST_INSTALL_SOURCE";

/// Resolve the install source, honoring the test override env var if set.
fn effective_install_source() -> &'static str {
    if let Ok(forced) = std::env::var(TEST_INSTALL_SOURCE_ENV) {
        match forced.as_str() {
            "release-tarball" => return "release-tarball",
            "cargo" => return "cargo",
            "dev" => return "dev",
            _ => {} // ignore garbage; fall through to real detection
        }
    }
    let cargo_home = std::env::var_os("CARGO_HOME").map(PathBuf::from);
    let binary_path = std::env::current_exe().ok();
    resolve_install_source(
        COMPILE_TIME_INSTALL_SOURCE,
        binary_path.as_deref(),
        cargo_home.as_deref(),
    )
}

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
    // Catches `~/.cargo/bin` even when CARGO_HOME is unset (common on macOS).
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
    pub(crate) fn build(state: &State) -> Self {
        Self {
            version: env!("CARGO_PKG_VERSION").to_string(),
            target: TARGET_TRIPLE.to_string(),
            install_source: effective_install_source().to_string(),
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

/// `cartog self version` entry point. Reads the on-disk state file, then
/// prints either a human-readable summary or a JSON object.
pub fn cmd_self_version(json: bool) -> Result<()> {
    let state = match state::default_state_file() {
        Some(p) => State::load_from(&p),
        None => State::default(),
    };
    let info = VersionInfo::build(&state);
    if json {
        println!("{}", serde_json::to_string_pretty(&info)?);
    } else {
        print!("{}", info.render_human());
    }
    Ok(())
}

/// `cartog self update [--check] [--quiet] [--json]` entry point.
///
/// In `--check` mode this is read-only (see [`run_check`]).
///
/// In upgrade mode the flow is:
/// 1. Refuse for cargo-installed binaries (exit 3) — direct user to
///    `cargo install cartog --force`.
/// 2. Refuse if a peer `cartog serve`/`watch` is still running (exit 6).
/// 3. Fetch the latest stable tag. Already up to date → exit 0.
/// 4. Download the platform tarball/zip and `SHA256SUMS`, verify the
///    checksum (exit 4 on mismatch), atomically swap the binary in
///    place, preserve `<bin>.old`, smoke-test the new binary
///    (exit 5 on failure → restore `.old`).
pub fn cmd_self_update(check: bool, quiet: bool, json: bool) -> Result<()> {
    if check {
        let exit_code = run_check(quiet, json);
        std::process::exit(exit_code);
    }
    let exit_code = run_upgrade(quiet, json);
    std::process::exit(exit_code);
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

/// `cartog self rollback` entry point.
///
/// Restores the binary previously saved at `<bin>.old` (created by a
/// successful `self update`) onto `<bin>`. The currently-running broken
/// binary is staged aside via `Move::replace_using_temp` and then deleted
/// so the user is left with a single binary and no leftover sibling.
///
/// Exit codes:
/// - `0` — successfully restored
/// - `1` — no `.old` to restore
/// - `2` — swap failed
///
/// Platform note: on Windows, renaming a running `.exe` is forbidden by
/// the OS and the swap will fail with exit 2. Users on Windows who need
/// to roll back must invoke rollback from a different running process.
pub fn cmd_self_rollback() -> Result<()> {
    let exit_code = run_rollback();
    std::process::exit(exit_code);
}

fn run_rollback() -> i32 {
    let current_bin = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cartog: cannot resolve current exe: {e}");
            return 2;
        }
    };
    let backup_path = backup_path_for(&current_bin);
    if !backup_path.exists() {
        eprintln!(
            "cartog: no previous binary to roll back to (looked for {})",
            backup_path.display(),
        );
        return 1;
    }

    // Stage the currently-running binary aside via a per-PID temp path so
    // a parallel `self update` cannot collide with our intermediate file.
    let install_dir = match current_bin.parent() {
        Some(p) => p,
        None => {
            eprintln!(
                "cartog: current exe {} has no parent directory",
                current_bin.display(),
            );
            return 2;
        }
    };
    let intermediate = install_dir.join(format!(".cartog.broken.{}.tmp", std::process::id()));

    if let Err(e) = self_update::Move::from_source(&backup_path)
        .replace_using_temp(&intermediate)
        .to_dest(&current_bin)
    {
        eprintln!("cartog: rollback failed: {e}");
        return 2;
    }

    // Per RD-2 the user is back to a single binary with no `.old` sibling.
    // Move::to_dest consumed `<bin>.old`, so only the staged broken binary
    // remains at `intermediate`. Best-effort delete; a failure here is
    // worth surfacing but does not invalidate the rollback.
    if let Err(e) = std::fs::remove_file(&intermediate) {
        tracing::warn!(
            error = %e,
            path = %intermediate.display(),
            "rollback succeeded but failed to clean up staged broken binary",
        );
    }

    println!(
        "cartog: rolled back to previous binary ({})",
        current_bin.display(),
    );
    0
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
        // Pin REST API version per GitHub docs — guards against silent schema drift.
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

// ── upgrade flow ──────────────────────────────────────────────────────

/// Exit codes for the upgrade path. Mirrors the contract documented on
/// [`cmd_self_update`].
mod exit {
    pub const SUCCESS: i32 = 0;
    pub const NETWORK_OR_PARSE_ERROR: i32 = 2;
    pub const CARGO_INSTALL_REFUSED: i32 = 3;
    pub const CHECKSUM_FAILED: i32 = 4;
    pub const DISK_OR_PERMISSION_FAILED: i32 = 5;
    pub const PEER_RUNNING: i32 = 6;
}

/// Drive the upgrade path and return the desired exit code.
fn run_upgrade(quiet: bool, json: bool) -> i32 {
    let source = effective_install_source();
    if source == "cargo" {
        emit_upgrade_message(
            quiet,
            json,
            "cargo",
            "cartog was installed via cargo. Run `cargo install cartog --force` to upgrade.",
        );
        return exit::CARGO_INSTALL_REFUSED;
    }

    if let Some(dir) = state::default_state_dir() {
        let active = cartog_process_lock::find_active_locks(&dir);
        if let Some(peer) = active.first() {
            emit_upgrade_message(
                quiet,
                json,
                "peer-running",
                &format!(
                    "another cartog process is running ({slot}, PID {pid}); stop it before updating",
                    slot = peer.slot,
                    pid = peer.pid,
                ),
            );
            return exit::PEER_RUNNING;
        }
    }

    // 3. Fetch latest release tag.
    let api_url = github_latest_url();
    let latest = match fetch_latest_version(&api_url) {
        Ok(v) => v,
        Err(e) => {
            emit_upgrade_message(quiet, json, "fetch-failed", &e.to_string());
            return exit::NETWORK_OR_PARSE_ERROR;
        }
    };
    let current = env!("CARGO_PKG_VERSION");
    if compare_stable_versions(current, &latest) != std::cmp::Ordering::Less {
        if !quiet {
            if json {
                let payload = serde_json::json!({
                    "status": "up-to-date",
                    "current": current,
                    "latest": latest,
                });
                println!("{payload}");
            } else {
                println!("cartog: already up to date ({current})");
            }
        }
        return exit::SUCCESS;
    }

    // 4. Download tarball + SHA256SUMS, verify, swap.
    match perform_upgrade(current, &latest, quiet, json) {
        Ok(()) => exit::SUCCESS,
        Err(UpgradeError::Network(msg)) => {
            emit_upgrade_message(quiet, json, "fetch-failed", &msg);
            exit::NETWORK_OR_PARSE_ERROR
        }
        Err(UpgradeError::Checksum(msg)) => {
            emit_upgrade_message(quiet, json, "checksum-failed", &msg);
            exit::CHECKSUM_FAILED
        }
        Err(UpgradeError::Filesystem(msg)) => {
            emit_upgrade_message(quiet, json, "filesystem-failed", &msg);
            exit::DISK_OR_PERMISSION_FAILED
        }
    }
}

/// Categorised error so [`run_upgrade`] can map to the right exit code.
enum UpgradeError {
    Network(String),
    Checksum(String),
    Filesystem(String),
}

fn perform_upgrade(
    current: &str,
    latest: &str,
    quiet: bool,
    json: bool,
) -> std::result::Result<(), UpgradeError> {
    let archive_name = archive_name_for(TARGET_TRIPLE);
    let download_base = github_download_base(latest);
    let archive_url = format!("{download_base}/{archive_name}");
    let sums_url = format!("{download_base}/SHA256SUMS");

    if !quiet && !json {
        println!("cartog: downloading {archive_name}");
    }

    let archive_bytes = http_get_bytes(&archive_url)
        .map_err(|e| UpgradeError::Network(format!("failed to download {archive_url}: {e}")))?;
    let sums_text = http_get_text(&sums_url)
        .map_err(|e| UpgradeError::Network(format!("failed to download {sums_url}: {e}")))?;

    let expected = parse_sha256sums(&sums_text, &archive_name).ok_or_else(|| {
        UpgradeError::Checksum(format!(
            "SHA256SUMS does not contain an entry for {archive_name}"
        ))
    })?;
    let actual = compute_sha256(&archive_bytes);
    if !actual.eq_ignore_ascii_case(&expected) {
        return Err(UpgradeError::Checksum(format!(
            "checksum mismatch for {archive_name}: expected {expected}, got {actual}"
        )));
    }

    // Stage in install_dir (same FS) — default $TMPDIR could trigger EXDEV on rename.
    let current_bin = std::env::current_exe()
        .map_err(|e| UpgradeError::Filesystem(format!("cannot resolve current exe: {e}")))?;
    let install_dir = current_bin.parent().ok_or_else(|| {
        UpgradeError::Filesystem(format!(
            "current exe {} has no parent directory",
            current_bin.display(),
        ))
    })?;
    // SIGKILL/SIGINT during a prior upgrade can orphan staging dirs (TempDir
    // Drop never runs). Sweep entries older than 1h before creating a new one.
    sweep_stale_staging_dirs(install_dir);
    let staging = tempfile::Builder::new()
        .prefix(".cartog-update-")
        .tempdir_in(install_dir)
        .map_err(|e| {
            UpgradeError::Filesystem(format!(
                "failed to create staging dir under {}: {e}",
                install_dir.display(),
            ))
        })?;
    let archive_path = staging.path().join(&archive_name);
    std::fs::write(&archive_path, &archive_bytes)
        .map_err(|e| UpgradeError::Filesystem(format!("failed to stage archive: {e}")))?;
    self_update::Extract::from_source(&archive_path)
        .extract_file(staging.path(), bin_name_in_archive())
        .map_err(|e| UpgradeError::Filesystem(format!("failed to extract binary: {e}")))?;
    let new_bin = staging.path().join(bin_name_in_archive());

    let backup_path = backup_path_for(&current_bin);

    self_update::Move::from_source(&new_bin)
        .replace_using_temp(&backup_path)
        .to_dest(&current_bin)
        .map_err(|e| UpgradeError::Filesystem(format!("atomic swap failed: {e}")))?;

    if let Err(smoke_err) = smoke_test(&current_bin) {
        match std::fs::rename(&backup_path, &current_bin) {
            Ok(()) => {
                return Err(UpgradeError::Filesystem(format!(
                    "new binary failed smoke test ({smoke_err}); previous binary restored"
                )));
            }
            Err(restore_err) => {
                // The new binary is broken AND we could not restore the old one.
                // The user must intervene manually. Be explicit about both failures.
                return Err(UpgradeError::Filesystem(format!(
                    "new binary failed smoke test ({smoke_err}) AND restore of {} -> {} \
                     also failed ({restore_err}); manually rename the .old back",
                    backup_path.display(),
                    current_bin.display(),
                )));
            }
        }
    }

    if let Some(state_path) = state::default_state_file() {
        let mut state = State::load_from(&state_path);
        state.last_known_latest = Some(latest.to_string());
        state.last_known_outdated = false;
        state.last_update_check = Some(rfc3339_now());
        if let Err(e) = state.save_to(&state_path) {
            tracing::warn!(
                error = %e,
                path = %state_path.display(),
                "failed to persist update state",
            );
        }
    }

    if !quiet {
        if json {
            let payload = serde_json::json!({
                "status": "updated",
                "current": current,
                "latest": latest,
                "backup": backup_path.to_string_lossy(),
            });
            println!("{payload}");
        } else {
            println!(
                "cartog: updated {current} -> {latest} (previous binary saved at {})",
                backup_path.display()
            );
        }
    }
    Ok(())
}

/// Emit a one-line status message in the right shape for the user.
fn emit_upgrade_message(quiet: bool, json: bool, status: &str, message: &str) {
    if quiet {
        return;
    }
    if json {
        let payload = serde_json::json!({
            "status": status,
            "message": message,
        });
        println!("{payload}");
    } else {
        eprintln!("cartog: {message}");
    }
}

const DEFAULT_GITHUB_DOWNLOAD_BASE: &str = "https://github.com/jrollin/cartog/releases/download";

/// Resolve the per-version download base URL. Honors
/// `CARTOG_GITHUB_DOWNLOAD_BASE` for tests and locked-down environments.
fn github_download_base(version: &str) -> String {
    let base = std::env::var("CARTOG_GITHUB_DOWNLOAD_BASE")
        .unwrap_or_else(|_| DEFAULT_GITHUB_DOWNLOAD_BASE.to_string());
    format!("{base}/v{version}")
}

/// Compose the platform-specific archive name. Mirrors the names produced
/// by the release workflow: tar.gz on unix, zip on windows. The version
/// is NOT embedded in the filename — it lives in the URL path
/// (`releases/download/v<version>/<archive>`), matching install.sh.
fn archive_name_for(target: &str) -> String {
    let ext = if target.contains("windows") {
        "zip"
    } else {
        "tar.gz"
    };
    format!("cartog-{target}.{ext}")
}

fn bin_name_in_archive() -> &'static str {
    if cfg!(windows) {
        "cartog.exe"
    } else {
        "cartog"
    }
}

fn backup_path_for(current: &Path) -> PathBuf {
    let mut name = current
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_else(|| std::ffi::OsString::from("cartog"));
    name.push(".old");
    current.with_file_name(name)
}

/// Find the hash for `archive_name` in a `sha256sum -c`-style file.
/// Lines look like `<hex>  <filename>` (two spaces or one + a `*`).
fn parse_sha256sums(text: &str, archive_name: &str) -> Option<String> {
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // Accept "<hash>  <name>", "<hash> *<name>", or "<hash> <name>".
        let mut parts = line.splitn(2, char::is_whitespace);
        let hash = parts.next()?.trim();
        let rest = parts.next()?.trim();
        let name = rest.strip_prefix('*').unwrap_or(rest).trim();
        if name == archive_name {
            return Some(hash.to_string());
        }
    }
    None
}

fn compute_sha256(bytes: &[u8]) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(bytes);
    let mut s = String::with_capacity(digest.len() * 2);
    for b in digest {
        use std::fmt::Write;
        let _ = write!(s, "{b:02x}");
    }
    s
}

fn http_get_bytes(url: &str) -> Result<Vec<u8>> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("cartog/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(60))
        .build()?;
    let response = client.get(url).send()?;
    let status = response.status();
    if !status.is_success() {
        anyhow::bail!("HTTP {status} from {url}");
    }
    Ok(response.bytes()?.to_vec())
}

fn http_get_text(url: &str) -> Result<String> {
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("cartog/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    let response = client.get(url).send()?;
    let status = response.status();
    if !status.is_success() {
        anyhow::bail!("HTTP {status} from {url}");
    }
    Ok(response.text()?)
}

/// Hard ceiling on how long we wait for the new binary's `--version` to
/// exit. A corrupt-but-not-crashing binary that hangs on startup would
/// otherwise hang `cartog self update` indefinitely with the swap
/// already done; the timeout lets the restore branch fire.
const SMOKE_TEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Stale staging directory cutoff. A previous upgrade killed by SIGINT
/// or SIGKILL leaves `.cartog-update-<rand>/` behind; anything older
/// than this is safely abandoned.
const STAGING_SWEEP_AGE: Duration = Duration::from_secs(3600);

/// Best-effort sweep of `.cartog-update-*` directories left behind by a
/// previous interrupted upgrade. Errors are swallowed — this runs as a
/// hygiene step before the real upgrade, never the operation the user
/// asked for.
fn sweep_stale_staging_dirs(install_dir: &Path) {
    let Ok(entries) = std::fs::read_dir(install_dir) else {
        return;
    };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        if !name_str.starts_with(".cartog-update-") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_dir() {
            continue;
        }
        let modified_age = meta
            .modified()
            .ok()
            .and_then(|m| now.duration_since(m).ok());
        if let Some(age) = modified_age {
            if age >= STAGING_SWEEP_AGE {
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
    }
}

fn smoke_test(bin: &Path) -> Result<()> {
    let mut child = std::process::Command::new(bin)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;

    let deadline = std::time::Instant::now() + SMOKE_TEST_TIMEOUT;
    loop {
        match child.try_wait()? {
            Some(status) => {
                if !status.success() {
                    anyhow::bail!("{bin:?} --version exited with {:?}", status.code());
                }
                return Ok(());
            }
            None => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    anyhow::bail!("{bin:?} --version did not exit within {SMOKE_TEST_TIMEOUT:?}");
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_name_drops_version_to_match_release_workflow() {
        assert_eq!(
            archive_name_for("aarch64-apple-darwin"),
            "cartog-aarch64-apple-darwin.tar.gz"
        );
        assert_eq!(
            archive_name_for("x86_64-pc-windows-msvc"),
            "cartog-x86_64-pc-windows-msvc.zip"
        );
    }

    #[test]
    fn parse_sha256sums_finds_named_entry() {
        let text = "\
abcd1234  cartog-aarch64-apple-darwin.tar.gz
deadbeef *cartog-x86_64-unknown-linux-gnu.tar.gz
# comment line
0123 cartog-x86_64-pc-windows-msvc.zip
";
        assert_eq!(
            parse_sha256sums(text, "cartog-aarch64-apple-darwin.tar.gz"),
            Some("abcd1234".to_string())
        );
        assert_eq!(
            parse_sha256sums(text, "cartog-x86_64-unknown-linux-gnu.tar.gz"),
            Some("deadbeef".to_string()),
            "binary-mode `*` prefix should be stripped"
        );
        assert_eq!(
            parse_sha256sums(text, "cartog-missing.tar.gz"),
            None,
            "absent entries should return None"
        );
    }

    #[test]
    fn compute_sha256_matches_known_vector() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        assert_eq!(
            compute_sha256(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        assert_eq!(
            compute_sha256(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    // is_leap / utc_breakdown / rfc3339_now tests live in `time_fmt::tests`.

    #[test]
    fn backup_path_appends_dot_old() {
        let bin = Path::new("/usr/local/bin/cartog");
        assert_eq!(
            backup_path_for(bin),
            PathBuf::from("/usr/local/bin/cartog.old")
        );
        // Windows-style suffix is preserved.
        let win = Path::new(r"C:\Program Files\cartog\cartog.exe");
        assert_eq!(
            backup_path_for(win),
            PathBuf::from(r"C:\Program Files\cartog\cartog.exe.old")
        );
    }

    #[test]
    fn bin_name_matches_target_os() {
        if cfg!(windows) {
            assert_eq!(bin_name_in_archive(), "cartog.exe");
        } else {
            assert_eq!(bin_name_in_archive(), "cartog");
        }
    }

    /// Write an executable shell script and return its path.
    #[cfg(unix)]
    fn write_exec_script(dir: &Path, name: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        std::fs::write(&path, body).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    #[cfg(unix)]
    #[test]
    fn smoke_test_passes_on_zero_exit() {
        let dir = tempfile::TempDir::new().unwrap();
        let bin = write_exec_script(dir.path(), "ok", "#!/bin/sh\nexit 0\n");
        smoke_test(&bin).expect("zero-exit binary must pass");
    }

    #[cfg(unix)]
    #[test]
    fn smoke_test_fails_on_non_zero_exit() {
        let dir = tempfile::TempDir::new().unwrap();
        let bin = write_exec_script(dir.path(), "fail", "#!/bin/sh\nexit 7\n");
        let err = smoke_test(&bin).expect_err("non-zero exit must fail");
        let msg = format!("{err:#}");
        assert!(msg.contains("exited with"), "got: {msg}");
    }

    #[cfg(unix)]
    #[test]
    fn smoke_test_kills_a_hung_binary_after_timeout() {
        // Override the timeout via the SMOKE_TEST_TIMEOUT constant is not
        // possible without exposing a seam; instead, the deadline branch
        // is reachable as long as the script sleeps longer than the
        // 5-second ceiling. To keep this fast, we use a script that
        // sleeps for 30s — the watchdog kills it within the 5s budget.
        // A regression that drops the timeout would hang this test for
        // 30 seconds; the test runner's per-test budget is the safety
        // net. Marked #[ignore] would mask the bug; better to fail loud.
        let dir = tempfile::TempDir::new().unwrap();
        let bin = write_exec_script(dir.path(), "hang", "#!/bin/sh\nsleep 30\n");
        let start = std::time::Instant::now();
        let err = smoke_test(&bin).expect_err("hanging binary must time out");
        let elapsed = start.elapsed();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("did not exit"),
            "expected timeout message, got: {msg}"
        );
        // Deadline is 5s; allow generous slack for slow CI but verify we
        // didn't actually wait the full 30s.
        assert!(
            elapsed < Duration::from_secs(15),
            "smoke_test should have killed the child within ~5s, took {elapsed:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn sweep_removes_old_staging_dirs_and_keeps_fresh() {
        use std::os::unix::fs::MetadataExt;

        let dir = tempfile::TempDir::new().unwrap();
        let stale = dir.path().join(".cartog-update-stale");
        let fresh = dir.path().join(".cartog-update-fresh");
        let unrelated = dir.path().join("not-a-staging-dir");
        std::fs::create_dir(&stale).unwrap();
        std::fs::create_dir(&fresh).unwrap();
        std::fs::create_dir(&unrelated).unwrap();

        // Backdate the stale dir's mtime via utimes(2) — filetime is not in
        // deps and `tempfile` doesn't expose mtime mutation.
        let two_hours_ago = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
            - 2 * 3600;
        let path_c = std::ffi::CString::new(stale.as_os_str().as_encoded_bytes()).unwrap();
        let times = [
            libc::timeval {
                tv_sec: two_hours_ago,
                tv_usec: 0,
            },
            libc::timeval {
                tv_sec: two_hours_ago,
                tv_usec: 0,
            },
        ];
        // SAFETY: utimes is POSIX; both args are valid pointers and `times`
        // points to a 2-element array as required.
        let rc = unsafe { libc::utimes(path_c.as_ptr(), times.as_ptr()) };
        assert_eq!(rc, 0, "utimes failed");
        let m = std::fs::metadata(&stale).unwrap();
        assert!(m.mtime() < two_hours_ago + 60);

        sweep_stale_staging_dirs(dir.path());

        assert!(!stale.exists(), "stale staging dir must be swept");
        assert!(fresh.exists(), "fresh staging dir must survive");
        assert!(unrelated.exists(), "non-cartog dirs must not be touched");
    }
}
