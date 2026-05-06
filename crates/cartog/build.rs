//! Emit compile-time env vars surfaced by `cartog --version` and `cartog self version`.

use std::env;
use std::process::Command;

fn main() {
    let sha = Command::new("git")
        .args(["rev-parse", "--short=10", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=CARTOG_BUILD_SHA={sha}");

    let mut features: Vec<String> = env::vars()
        .filter_map(|(k, _)| {
            k.strip_prefix("CARGO_FEATURE_")
                .map(|rest| rest.to_ascii_lowercase().replace('_', "-"))
        })
        .collect();
    features.sort();
    let features_str = if features.is_empty() {
        "none".to_string()
    } else {
        features.join(", ")
    };
    println!("cargo:rustc-env=CARTOG_BUILD_FEATURES={features_str}");

    // Cargo-installed binaries are detected at runtime by inspecting the
    // binary path; only release-tarball vs dev is decidable at build time.
    let install_source = if env::var_os("CARTOG_RELEASE_BUILD").is_some() {
        "release-tarball"
    } else {
        "dev"
    };
    println!("cargo:rustc-env=CARTOG_INSTALL_SOURCE={install_source}");
    println!("cargo:rerun-if-env-changed=CARTOG_RELEASE_BUILD");

    let target = env::var("TARGET").unwrap_or_else(|_| "unknown".to_string());
    println!("cargo:rustc-env=CARTOG_TARGET_TRIPLE={target}");

    // Resolve via git so worktrees (.git as a file) work; fall back gracefully
    // when not in a checkout (e.g. `cargo install` from crates.io).
    let head_path = Command::new("git")
        .args(["rev-parse", "--git-path", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    match head_path {
        Some(p) => println!("cargo:rerun-if-changed={p}"),
        None => println!("cargo:rerun-if-env-changed=CARTOG_BUILD_SHA"),
    }
}
