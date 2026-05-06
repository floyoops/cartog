//! Cross-process integration tests for the PID-file lock.
//!
//! Unit tests inside `process_lock.rs` cover the single-process happy paths.
//! These tests spawn a real child process so we can observe a *live* PID
//! belonging to a process other than the test runner itself, then kill it
//! and assert the next call cleans the stale file up.
//!
//! Gated to unix only: spawning `cmd /C timeout` on Windows leaves the
//! `timeout.exe` grandchild orphaned when we kill the cmd parent, which
//! would leak processes. Windows coverage stays in the unit tests inside
//! `process_lock.rs`.

#![cfg(unix)]

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// Spawn a long-lived child process (sleeps for a while) and write its PID
/// to `<state_dir>/<slot>.pid`. Returns the live `Child` so the caller can
/// kill it later.
fn spawn_pid_holder(state_dir: &Path, slot: &str) -> Child {
    std::fs::create_dir_all(state_dir).unwrap();
    let child = sleeping_child();
    let pid = child.id();
    let path = state_dir.join(format!("{slot}.pid"));
    std::fs::write(&path, pid.to_string()).unwrap();
    child
}

fn sleeping_child() -> Child {
    Command::new("sleep")
        .arg("60")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn sleep")
}

/// Wait briefly for `pred` to become true, then return its outcome. Used to
/// give the OS a chance to reap a killed process before we re-check
/// liveness.
fn wait_until<F: FnMut() -> bool>(mut pred: F, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    loop {
        if pred() {
            return true;
        }
        if start.elapsed() >= timeout {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn process_lock_test_finds_live_external_pid() {
    let dir = tempfile::TempDir::new().unwrap();
    let mut child = spawn_pid_holder(dir.path(), "watch");

    let active = cartog_lib::find_active_locks(dir.path());
    assert_eq!(active.len(), 1, "expected exactly one active lock");
    assert_eq!(active[0].slot, "watch");
    assert_eq!(active[0].pid, child.id());

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn process_lock_test_cleans_stale_after_child_exits() {
    let dir = tempfile::TempDir::new().unwrap();
    let mut child = spawn_pid_holder(dir.path(), "serve");
    let pid = child.id();
    child.kill().expect("kill child");
    child.wait().expect("reap child");

    // Some platforms reap asynchronously; give the kernel a moment.
    let dead = wait_until(|| !cartog_lib::is_alive(pid), Duration::from_secs(2));
    assert!(dead, "child PID {pid} should be reported dead after wait");

    let active = cartog_lib::find_active_locks(dir.path());
    assert!(
        active.is_empty(),
        "killed child's PID file should be cleaned up, got {active:?}"
    );
    assert!(
        !dir.path().join("serve.pid").exists(),
        "stale pid file must be deleted by find_active_locks"
    );
}

// ── glue: pull `process_lock` in via the cartog library facade ────────
//
// The module is exposed on `lib.rs` (with `#[doc(hidden)]`) precisely so
// integration tests can reach it; this little shim just lets us write
// `cartog_lib::is_alive` instead of the longer `cartog::process_lock::…`
// inside the test bodies.
mod cartog_lib {
    pub use cartog::process_lock::{find_active_locks, is_alive};
}
