//! Integration tests for `cartog self`.
//!
//! Each test invokes the real binary built by cargo (`CARGO_BIN_EXE_cartog`)
//! as a subprocess. Tests that touch the on-disk state file run in a
//! temporary $HOME / $XDG_STATE_HOME so they cannot pollute the developer's
//! actual cartog state.

use std::path::PathBuf;
use std::process::Command;

fn cartog_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_cartog"))
}

/// Spawn `cartog self version` (optionally with `--json`) in an isolated
/// HOME / XDG_STATE_HOME so the read of `state.toml` cannot escape into the
/// developer's real config directory.
fn run_self_version(args: &[&str], state_dir: &std::path::Path) -> std::process::Output {
    Command::new(cartog_bin())
        .arg("self")
        .arg("version")
        .args(args)
        .env("HOME", state_dir)
        .env("XDG_STATE_HOME", state_dir.join("state"))
        .env("XDG_DATA_HOME", state_dir.join("data"))
        .env("XDG_CONFIG_HOME", state_dir.join("config"))
        .env_remove("CARGO_HOME")
        .output()
        .expect("failed to spawn cartog")
}

#[test]
fn self_version_human_output_lists_required_fields() {
    let dir = tempfile::TempDir::new().unwrap();
    let out = run_self_version(&[], dir.path());
    assert!(
        out.status.success(),
        "cartog self version exited non-zero: stderr={}",
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    // Version line — package version is baked at build time.
    assert!(
        stdout.contains(env!("CARGO_PKG_VERSION")),
        "stdout missing version: {stdout}"
    );
    // Required labels per the user-facing acceptance criteria.
    assert!(
        stdout.contains("target:"),
        "stdout missing target: {stdout}"
    );
    assert!(
        stdout.contains("install source:"),
        "stdout missing install source: {stdout}"
    );
    assert!(
        stdout.contains("last update check:"),
        "stdout missing last update check: {stdout}"
    );
    // No prior check ran in this isolated state dir.
    assert!(
        stdout.contains("never"),
        "fresh state should report 'never': {stdout}"
    );
}

#[test]
fn self_version_json_emits_required_keys() {
    let dir = tempfile::TempDir::new().unwrap();
    let out = run_self_version(&["--json"], dir.path());
    assert!(
        out.status.success(),
        "cartog self version --json exited non-zero: stderr={}",
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let parsed: serde_json::Value =
        serde_json::from_str(&stdout).unwrap_or_else(|e| panic!("invalid JSON {stdout:?}: {e}"));
    let obj = parsed.as_object().expect("top-level JSON object");

    assert_eq!(
        obj.get("version").and_then(|v| v.as_str()),
        Some(env!("CARGO_PKG_VERSION")),
        "version mismatch in {stdout}"
    );
    let target = obj
        .get("target")
        .and_then(|v| v.as_str())
        .expect("target field");
    assert!(!target.is_empty(), "target should be a non-empty triple");
    let source = obj
        .get("install_source")
        .and_then(|v| v.as_str())
        .expect("install_source field");
    assert!(
        matches!(source, "release-tarball" | "cargo" | "dev"),
        "unexpected install_source: {source:?}"
    );
    // `last_update_check` is present and null on a fresh state file.
    assert!(
        obj.contains_key("last_update_check"),
        "missing last_update_check key in {stdout}"
    );
    assert!(
        obj["last_update_check"].is_null(),
        "fresh state should serialise null, got {:?}",
        obj["last_update_check"],
    );
}

/// Path where the binary will look for `state.toml` given a fake HOME, on the
/// platforms this test currently runs on (Linux + macOS).
///
/// Windows seeds via the `FOLDERID_LocalAppData` known folder, which a fake
/// HOME does not redirect — so this helper is intentionally not implemented
/// for Windows. If/when Windows CI is added the test must seed via
/// `LOCALAPPDATA` (or skip the seeded-state assertion).
#[cfg(not(target_os = "windows"))]
fn seeded_state_path(fake_home: &std::path::Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        fake_home
            .join("Library")
            .join("Application Support")
            .join("io.cartog.cartog")
            .join("state.toml")
    } else {
        // Linux: state_dir = $XDG_STATE_HOME/cartog (we override XDG_STATE_HOME below).
        fake_home.join("state").join("cartog").join("state.toml")
    }
}

#[cfg(not(target_os = "windows"))]
#[test]
fn self_version_reports_existing_check_timestamp() {
    let dir = tempfile::TempDir::new().unwrap();
    let state_file = seeded_state_path(dir.path());
    std::fs::create_dir_all(state_file.parent().unwrap()).unwrap();
    std::fs::write(
        &state_file,
        "last_update_check = \"2026-01-15T10:00:00Z\"\n",
    )
    .unwrap();

    let out = run_self_version(&["--json"], dir.path());
    assert!(
        out.status.success(),
        "cartog self version --json exited non-zero: stderr={}",
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("valid JSON");
    assert_eq!(
        parsed["last_update_check"].as_str(),
        Some("2026-01-15T10:00:00Z"),
        "did not pick up seeded timestamp at {state_file:?} from {stdout}"
    );
}
