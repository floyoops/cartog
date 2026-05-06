//! Persistent CLI state — last update check, last known latest version, etc.
//!
//! State lives in an XDG-compliant per-platform directory resolved via the
//! `directories` crate:
//!
//! - Linux:   `$XDG_STATE_HOME/cartog/state.toml` (typically `~/.local/state/cartog/`)
//! - macOS:   `~/Library/Application Support/cartog/state.toml`
//! - Windows: `%LOCALAPPDATA%\cartog\state.toml`
//!
//! The schema is intentionally tiny and forward-compatible: unknown TOML keys
//! are silently ignored, and a missing file deserialises to `State::default()`.
//! Writes are atomic (write-temp + rename) so concurrent invocations cannot
//! observe a torn file.

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const FILE_NAME: &str = "state.toml";

/// Persisted CLI state. All fields are optional — an empty file is valid and
/// deserialises to `State::default()`.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    /// RFC3339 timestamp of the last successful update check. `None` if no
    /// check has ever run on this machine.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_update_check: Option<String>,

    /// Latest stable version observed by the most recent check (e.g. `"0.14.0"`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_known_latest: Option<String>,

    /// Whether the current binary was outdated at the last check.
    #[serde(default, skip_serializing_if = "is_false")]
    pub last_known_outdated: bool,

    /// Mirror of `CARTOG_NO_UPDATE_CHECK` at the moment of the last write.
    /// Lets the next invocation honor a kill-switch without re-reading env on
    /// the hot path.
    #[serde(default, skip_serializing_if = "is_false")]
    pub update_check_disabled: bool,
}

#[allow(clippy::trivially_copy_pass_by_ref)]
fn is_false(b: &bool) -> bool {
    !*b
}

/// Resolve the platform-specific state directory. Hosts both
/// `state.toml` and the PID lock files written by long-lived commands.
///
/// Returns `None` if no home/state directory could be resolved (e.g. a
/// sandboxed environment with neither `$HOME` nor `%USERPROFILE%`).
pub fn default_state_dir() -> Option<PathBuf> {
    let proj = ProjectDirs::from("io", "cartog", "cartog")?;
    // state_dir is Linux-only; macOS/Windows fall back to data_local_dir.
    Some(
        proj.state_dir()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| proj.data_local_dir().to_path_buf()),
    )
}

/// Resolve the platform-specific state file path (`state.toml` inside
/// [`default_state_dir`]).
pub fn default_state_file() -> Option<PathBuf> {
    Some(default_state_dir()?.join(FILE_NAME))
}

impl State {
    /// Load state from `path`. A missing file or malformed TOML yields
    /// `State::default()` — this is a best-effort cache, not an authoritative
    /// store.
    pub fn load_from(path: &Path) -> Self {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Self::default(),
            Err(e) => {
                // tracing, not eprintln: avoid every-command stderr noise.
                tracing::warn!(
                    path = %path.display(),
                    error = %e,
                    "failed to read cartog state file; using defaults"
                );
                return Self::default();
            }
        };
        match toml::from_str::<State>(&text) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    path = %path.display(),
                    error = %e,
                    "cartog state file is malformed; using defaults"
                );
                Self::default()
            }
        }
    }

    /// Atomically persist state to `path`. The parent directory is created if
    /// missing. The write goes to a sibling temp file first, then `rename`s
    /// onto the target — readers never observe a partial write.
    pub fn save_to(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let serialized = toml::to_string(self).map_err(|e| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("failed to serialise state: {e}"),
            )
        })?;
        // Sibling tmp keeps the rename within one filesystem (no EXDEV).
        // Per-PID disambiguation: two cartog processes saving concurrently
        // (e.g. an auto-check thread and a `self update`) must not race on
        // the same tmp filename — the loser's rename would clobber the
        // winner's data.
        let tmp = match path.file_name() {
            Some(name) => path.with_file_name(format!(
                ".{}.{}.tmp",
                name.to_string_lossy(),
                std::process::id(),
            )),
            None => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "state path has no file name",
                ));
            }
        };
        std::fs::write(&tmp, serialized)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn load_missing_file_returns_default() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        let state = State::load_from(&path);
        assert_eq!(state, State::default());
    }

    #[test]
    fn save_then_load_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        let original = State {
            last_update_check: Some("2026-05-06T14:32:00Z".to_string()),
            last_known_latest: Some("0.14.0".to_string()),
            last_known_outdated: true,
            update_check_disabled: false,
        };
        original.save_to(&path).expect("save");
        let loaded = State::load_from(&path);
        assert_eq!(loaded, original);
    }

    #[test]
    fn save_creates_parent_directory() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("subdir").join("state.toml");
        State::default().save_to(&path).expect("save");
        assert!(path.exists());
    }

    #[test]
    fn malformed_toml_returns_default_without_panicking() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        std::fs::write(&path, "{{ not toml at all").unwrap();
        let state = State::load_from(&path);
        assert_eq!(state, State::default());
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        // A future schema version may add fields; old binaries must keep
        // working — forward-compatibility.
        std::fs::write(
            &path,
            "last_known_latest = \"0.15.0\"\nfuture_field = \"hello\"\n",
        )
        .unwrap();
        let state = State::load_from(&path);
        assert_eq!(state.last_known_latest.as_deref(), Some("0.15.0"));
    }

    #[test]
    fn empty_file_loads_as_default() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        std::fs::write(&path, "").unwrap();
        let state = State::load_from(&path);
        assert_eq!(state, State::default());
    }

    #[test]
    fn save_omits_default_fields_for_compactness() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        State::default().save_to(&path).expect("save");
        let text = std::fs::read_to_string(&path).unwrap();
        // Default state should serialise to an empty document (no keys).
        // Skip-if-default keeps the file readable for humans.
        assert!(
            !text.contains("last_update_check"),
            "default state should not write last_update_check, got: {text:?}"
        );
        assert!(
            !text.contains("last_known_outdated"),
            "default state should not write last_known_outdated, got: {text:?}"
        );
    }

    #[test]
    fn save_overwrites_existing_atomically() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.toml");
        State {
            last_known_latest: Some("0.13.0".to_string()),
            ..Default::default()
        }
        .save_to(&path)
        .expect("first save");
        State {
            last_known_latest: Some("0.14.0".to_string()),
            ..Default::default()
        }
        .save_to(&path)
        .expect("second save");
        let loaded = State::load_from(&path);
        assert_eq!(loaded.last_known_latest.as_deref(), Some("0.14.0"));
    }

    #[test]
    fn default_path_resolves_or_returns_none_gracefully() {
        // `default_path` should never panic. On a normal dev workstation it
        // returns Some; in a sandbox without a home directory it returns None.
        // Either is acceptable — the test just asserts no panic.
        let _ = default_state_file();
        let _ = default_state_dir();
    }
}
