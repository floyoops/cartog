//! Integration smoke tests for the auto-check predicate.
//!
//! The bulk of `should_check` coverage lives as unit tests in the module
//! itself. This file just confirms the predicate is reachable through the
//! cartog library facade and exercises a couple of representative cases —
//! enough that the verify command (`--test auto_check_test should_check`)
//! has something to run.

use std::time::{Duration, SystemTime};

use cartog::auto_check::{should_check, CheckMode, CommandKind, ShouldCheckInput};

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
