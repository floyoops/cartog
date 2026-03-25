use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Top-level cartog configuration, loaded from `.cartog.toml`.
///
/// Priority (highest to lowest):
/// 1. `--db` CLI flag / `CARTOG_DB` env var  (handled in main)
/// 2. `.cartog.toml` at git root or cwd      (`database.path`)
/// 3. Auto git-root detection                (no config needed)
/// 4. cwd fallback
#[derive(Debug, Default, Deserialize)]
pub struct CartogConfig {
    pub database: Option<DatabaseConfig>,
}

#[derive(Debug, Default, Deserialize)]
pub struct DatabaseConfig {
    /// Filesystem path to the cartog SQLite database. Supports `~` expansion.
    pub path: Option<String>,
}

/// Load the local project config from `.cartog.toml`.
pub fn load_config() -> CartogConfig {
    local_config_path()
        .and_then(|p| read_config(&p))
        .unwrap_or_default()
}

/// Path to the local project config: `.cartog.toml` found by walking up from
/// cwd to the git root. Returns `None` if no such file exists.
fn local_config_path() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        let candidate = dir.join(".cartog.toml");
        if candidate.exists() {
            return Some(candidate);
        }
        // Stop searching once we reach the git root without finding a config.
        if dir.join(".git").exists() {
            return None;
        }
        if !dir.pop() {
            break;
        }
    }
    None
}

fn read_config(path: &Path) -> Option<CartogConfig> {
    let text = std::fs::read_to_string(path).ok()?;
    match toml::from_str::<CartogConfig>(&text) {
        Ok(cfg) => Some(cfg),
        Err(e) => {
            // Use eprintln rather than tracing — tracing may not be initialised yet.
            eprintln!("cartog: warning: failed to parse {}: {e}", path.display());
            None
        }
    }
}

/// Expand a leading `~/` to the user's home directory.
pub fn expand_tilde(p: PathBuf) -> PathBuf {
    let s = p.to_string_lossy();
    if let Some(rest) = s.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")) {
            return PathBuf::from(home).join(rest);
        }
    }
    p
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_expand_tilde_with_home() {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| "/tmp".into());
        let expanded = expand_tilde(PathBuf::from("~/foo/bar"));
        assert_eq!(expanded, PathBuf::from(home).join("foo/bar"));
    }

    #[test]
    fn test_expand_tilde_no_tilde() {
        let p = PathBuf::from("/absolute/path");
        assert_eq!(expand_tilde(p.clone()), p);
    }

    #[test]
    fn test_read_config_valid_toml() {
        let dir = tempfile::TempDir::new().unwrap();
        let cfg_path = dir.path().join("config.toml");
        fs::write(&cfg_path, "[database]\npath = \"/tmp/test.db\"\n").unwrap();
        let cfg = read_config(&cfg_path).expect("should parse");
        assert_eq!(
            cfg.database.as_ref().unwrap().path.as_deref(),
            Some("/tmp/test.db")
        );
    }

    #[test]
    fn test_read_config_missing_file_returns_none() {
        let result = read_config(Path::new("/nonexistent/path/config.toml"));
        assert!(result.is_none());
    }

    #[test]
    fn test_read_config_empty_toml_returns_default() {
        let dir = tempfile::TempDir::new().unwrap();
        let cfg_path = dir.path().join("config.toml");
        fs::write(&cfg_path, "").unwrap();
        let cfg = read_config(&cfg_path).expect("empty toml is valid");
        assert!(cfg.database.is_none());
    }
}
