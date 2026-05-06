//! Cross-process integration tests for the PID-file lock (unix-only — Windows
//! `cmd /C timeout` orphans the `timeout.exe` grandchild on parent kill).

#![cfg(unix)]

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

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

// Shorter alias for cartog::process_lock in test bodies.
mod cartog_lib {
    pub use cartog::process_lock::{find_active_locks, is_alive};
}
