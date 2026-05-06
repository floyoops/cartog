//! Integration smoke tests for the auto-check predicate.
//!
//! The bulk of `should_check` coverage lives as unit tests in the module
//! itself. This file just confirms the predicate is reachable through the
//! cartog library facade and exercises a couple of representative cases —
//! enough that the verify command (`--test auto_check_test should_check`)
//! has something to run.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant, SystemTime};

use cartog::auto_check::{
    run_check_once, should_check, spawn_check, CheckMode, CommandKind, ShouldCheckInput,
};
use cartog::state::State;

fn now() -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_704_067_200) // 2024-01-01T00:00:00Z
}

#[test]
fn should_check_first_run_with_tty_via_lib_facade() {
    let input = ShouldCheckInput {
        command_kind: CommandKind::Quick,
        stdout_is_tty: true,
        disabled_env: false,
        mode: CheckMode::Daily,
        last_check: None,
        now: now(),
    };
    assert!(should_check(&input));
}

#[test]
fn should_check_serve_command_blocked_via_lib_facade() {
    let input = ShouldCheckInput {
        command_kind: CommandKind::LongLived,
        stdout_is_tty: true,
        disabled_env: false,
        mode: CheckMode::Always,
        last_check: None,
        now: now(),
    };
    assert!(!should_check(&input), "serve/watch must never auto-check");
}

// ── spawn_check / run_check_once ──────────────────────────────────────

/// Stand up a localhost HTTP server that serves a single canned 200 OK
/// response and exits. Same shape as the helper in `self_update_test.rs`,
/// duplicated here to keep the integration test crates independent.
fn spawn_canned_github_response(json_body: String) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind localhost");
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            let body = json_body.as_bytes();
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.write_all(body);
            let _ = stream.flush();
        }
    });
    format!("http://127.0.0.1:{port}/")
}

fn wait_for<F: FnMut() -> bool>(mut pred: F, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if pred() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    pred()
}

#[test]
fn spawn_check_run_once_writes_state_when_outdated() {
    let dir = tempfile::TempDir::new().unwrap();
    let state_path = dir.path().join("state.toml");
    let url = spawn_canned_github_response(r#"{"tag_name":"v999.0.0"}"#.to_string());

    run_check_once(&url, Some(&state_path), env!("CARGO_PKG_VERSION")).expect("check ok");

    let state = State::load_from(&state_path);
    assert_eq!(
        state.last_known_latest.as_deref(),
        Some("999.0.0"),
        "state should record the fetched latest version"
    );
    assert!(state.last_known_outdated, "v999.0.0 must be newer");
    assert!(
        state.last_update_check.is_some(),
        "last_update_check must be populated"
    );
}

#[test]
fn spawn_check_run_once_marks_not_outdated_when_current() {
    let dir = tempfile::TempDir::new().unwrap();
    let state_path = dir.path().join("state.toml");
    let url = spawn_canned_github_response(format!(
        r#"{{"tag_name":"v{}"}}"#,
        env!("CARGO_PKG_VERSION")
    ));

    run_check_once(&url, Some(&state_path), env!("CARGO_PKG_VERSION")).expect("check ok");

    let state = State::load_from(&state_path);
    assert_eq!(
        state.last_known_latest.as_deref(),
        Some(env!("CARGO_PKG_VERSION")),
    );
    assert!(
        !state.last_known_outdated,
        "running version == latest must not be marked outdated"
    );
}

#[test]
fn spawn_check_returns_immediately_without_blocking() {
    // The main process should not wait on the worker. We verify by
    // measuring the call duration: spawning a thread is microseconds, the
    // network probe takes ~10ms+, so a 50ms ceiling clearly proves we
    // didn't synchronously wait for completion.
    let dir = tempfile::TempDir::new().unwrap();
    let state_path = dir.path().join("state.toml");
    let url = spawn_canned_github_response(r#"{"tag_name":"v999.0.0"}"#.to_string());

    let start = Instant::now();
    spawn_check(
        url,
        Some(state_path.clone()),
        env!("CARGO_PKG_VERSION").to_string(),
    );
    let spawn_elapsed = start.elapsed();
    assert!(
        spawn_elapsed < Duration::from_millis(50),
        "spawn_check returned in {:?}; should not have blocked on the network call",
        spawn_elapsed
    );

    // The worker should eventually finish and write the state file.
    assert!(
        wait_for(|| state_path.exists(), Duration::from_secs(2)),
        "worker thread should have produced state.toml within 2s"
    );
}

#[test]
fn spawn_check_run_once_skips_state_save_when_path_is_none() {
    let url = spawn_canned_github_response(r#"{"tag_name":"v999.0.0"}"#.to_string());
    // Should still succeed; just skips the state write.
    run_check_once(&url, None, env!("CARGO_PKG_VERSION")).expect("check with no state path");
}

#[test]
fn spawn_check_run_once_rejects_prerelease_tags() {
    let dir = tempfile::TempDir::new().unwrap();
    let state_path = dir.path().join("state.toml");
    let url = spawn_canned_github_response(r#"{"tag_name":"v0.14.0-rc.1"}"#.to_string());

    let err = run_check_once(&url, Some(&state_path), env!("CARGO_PKG_VERSION"))
        .expect_err("prerelease must not be treated as eligible");
    assert!(
        format!("{err}").contains("parse"),
        "expected a parse error, got: {err}"
    );
    assert!(
        !state_path.exists(),
        "state file must not be written on parse failure"
    );
}
