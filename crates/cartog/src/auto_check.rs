//! Auto-check predicate and helpers for the daily background update probe.
//!
//! The actual thread spawn lands in a follow-up task; this module owns the
//! "should we even bother?" decision so it can be unit-tested in isolation
//! from the network and the filesystem.

use std::time::{Duration, SystemTime};

/// Kind of command currently running. Long-lived commands (`serve`,
/// `watch`) deliberately skip the auto-check — they are typically started
/// by editor integrations, run for hours, and the user never sees a hint
/// printed at the *start* anyway.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind {
    Quick,
    LongLived,
}

/// Resolved interval policy. Mirrors `CARTOG_UPDATE_CHECK={never,daily,always}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckMode {
    Never,
    Daily,
    Always,
}

/// Inputs to the [`should_check`] predicate. Bundled into a struct so the
/// pure decision is trivially testable — tests construct an input by hand;
/// the binary fills it from real env / FS state.
#[derive(Debug, Clone)]
pub struct ShouldCheckInput<'a> {
    pub command_kind: CommandKind,
    pub stdout_is_tty: bool,
    /// `CARTOG_NO_UPDATE_CHECK=1` (any non-empty value) disables the check.
    pub disabled_env: bool,
    pub mode: CheckMode,
    /// RFC3339 timestamp of the last check, or `None` if never.
    pub last_check: Option<&'a str>,
    pub now: SystemTime,
}

const DAILY_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// Pure decision: should the post-command epilogue spawn an update-check
/// thread? Returns `true` iff every gating signal allows it.
pub fn should_check(input: &ShouldCheckInput<'_>) -> bool {
    if input.disabled_env {
        return false;
    }
    if matches!(input.mode, CheckMode::Never) {
        return false;
    }
    if matches!(input.command_kind, CommandKind::LongLived) {
        return false;
    }
    if !input.stdout_is_tty {
        return false;
    }
    if matches!(input.mode, CheckMode::Always) {
        return true;
    }
    // Daily: only fire when no check has happened in the past 24h.
    match input.last_check.and_then(parse_rfc3339_secs) {
        Some(last_secs) => match input.now.duration_since(SystemTime::UNIX_EPOCH) {
            Ok(now_secs) => {
                now_secs.saturating_sub(Duration::from_secs(last_secs)) >= DAILY_INTERVAL
            }
            // Pre-epoch clock — treat as "no record", check anyway.
            Err(_) => true,
        },
        // No prior record (or unparseable) — first run, definitely check.
        None => true,
    }
}

/// Parse `CARTOG_UPDATE_CHECK` into a [`CheckMode`]. Unknown / unset values
/// fall back to `Daily` so users never accidentally disable themselves.
pub fn parse_check_mode(raw: Option<&str>) -> CheckMode {
    match raw.map(str::trim).map(str::to_ascii_lowercase).as_deref() {
        Some("never") => CheckMode::Never,
        Some("always") => CheckMode::Always,
        _ => CheckMode::Daily,
    }
}

/// `CARTOG_NO_UPDATE_CHECK` kill switch: any non-empty value disables.
pub fn parse_disabled_env(raw: Option<&str>) -> bool {
    matches!(raw, Some(v) if !v.is_empty())
}

/// Parse a `YYYY-MM-DDTHH:MM:SSZ` timestamp into seconds since Unix epoch.
/// Returns `None` for any deviation from that exact shape — we own the
/// writer (`rfc3339_now` in `commands::self_cmd`) so a stricter parser
/// is fine here.
fn parse_rfc3339_secs(s: &str) -> Option<u64> {
    let bytes = s.as_bytes();
    if bytes.len() != 20 || bytes[19] != b'Z' {
        return None;
    }
    let read = |i: usize, n: usize| -> Option<u64> {
        let slice = std::str::from_utf8(&bytes[i..i + n]).ok()?;
        slice.parse::<u64>().ok()
    };
    if bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    let year = read(0, 4)?;
    let month = read(5, 2)?;
    let day = read(8, 2)?;
    let hour = read(11, 2)?;
    let minute = read(14, 2)?;
    let second = read(17, 2)?;
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        // We own the writer (`rfc3339_now`) and it never emits 60, so
        // rejecting 60 keeps the arithmetic exact (no over-count).
        || second > 59
    {
        return None;
    }
    Some(days_since_epoch(year, month, day)? * 86_400 + hour * 3600 + minute * 60 + second)
}

/// Compute days from 1970-01-01 to (year, month, day). Returns `None` for
/// invalid month/day combinations (e.g. 2023-02-30).
fn days_since_epoch(year: u64, month: u64, day: u64) -> Option<u64> {
    if year < 1970 {
        return None;
    }
    let mut days: u64 = 0;
    for y in 1970..year {
        days += if is_leap(y as u32) { 366 } else { 365 };
    }
    let months = [31u64, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for (idx, &dm) in months.iter().enumerate() {
        let m = (idx + 1) as u64;
        if m >= month {
            break;
        }
        let dm = if idx == 1 && is_leap(year as u32) {
            29
        } else {
            dm
        };
        days += dm;
    }
    let dim = if month == 2 && is_leap(year as u32) {
        29
    } else {
        months[(month - 1) as usize]
    };
    if day > dim {
        return None;
    }
    Some(days + day - 1)
}

fn is_leap(year: u32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn epoch_plus(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
    }

    fn input_default<'a>(now_secs: u64) -> ShouldCheckInput<'a> {
        ShouldCheckInput {
            command_kind: CommandKind::Quick,
            stdout_is_tty: true,
            disabled_env: false,
            mode: CheckMode::Daily,
            last_check: None,
            now: epoch_plus(now_secs),
        }
    }

    #[test]
    fn should_check_first_run_with_tty_returns_true() {
        let input = input_default(1_000_000);
        assert!(should_check(&input));
    }

    #[test]
    fn should_check_disabled_env_blocks() {
        let mut input = input_default(1_000_000);
        input.disabled_env = true;
        assert!(!should_check(&input));
    }

    #[test]
    fn should_check_never_mode_blocks() {
        let mut input = input_default(1_000_000);
        input.mode = CheckMode::Never;
        assert!(!should_check(&input));
    }

    #[test]
    fn should_check_long_lived_commands_blocked() {
        let mut input = input_default(1_000_000);
        input.command_kind = CommandKind::LongLived;
        assert!(!should_check(&input));
    }

    #[test]
    fn should_check_non_tty_blocked() {
        let mut input = input_default(1_000_000);
        input.stdout_is_tty = false;
        assert!(!should_check(&input));
    }

    #[test]
    fn should_check_always_mode_overrides_interval() {
        let mut input = input_default(1_000_000);
        input.mode = CheckMode::Always;
        // Last check was just a moment ago; daily mode would refuse, but
        // always mode does not consult the interval.
        input.last_check = Some("1970-01-12T13:46:39Z");
        assert!(should_check(&input));
    }

    #[test]
    fn should_check_daily_within_24h_blocked() {
        // last_check = 2024-01-01T00:00:00Z; now = 2024-01-01T12:00:00Z.
        let last_secs: u64 = 1_704_067_200;
        let now_secs = last_secs + 12 * 3600;
        let mut input = input_default(now_secs);
        input.last_check = Some("2024-01-01T00:00:00Z");
        assert!(!should_check(&input));
    }

    #[test]
    fn should_check_daily_after_24h_allowed() {
        let last_secs: u64 = 1_704_067_200;
        let now_secs = last_secs + 25 * 3600;
        let mut input = input_default(now_secs);
        input.last_check = Some("2024-01-01T00:00:00Z");
        assert!(should_check(&input));
    }

    #[test]
    fn should_check_daily_unparseable_last_treated_as_never() {
        let mut input = input_default(1_000_000);
        input.last_check = Some("not a real timestamp");
        assert!(should_check(&input));
    }

    #[test]
    fn should_check_long_lived_beats_always_mode() {
        // Long-lived gating runs before mode==Always so `serve` never
        // triggers a check, even with `CARTOG_UPDATE_CHECK=always`.
        let mut input = input_default(1_000_000);
        input.command_kind = CommandKind::LongLived;
        input.mode = CheckMode::Always;
        assert!(!should_check(&input));
    }

    #[test]
    fn should_check_disabled_env_beats_always_mode() {
        let mut input = input_default(1_000_000);
        input.disabled_env = true;
        input.mode = CheckMode::Always;
        assert!(!should_check(&input));
    }

    // ── parse_check_mode ──

    #[test]
    fn parse_check_mode_known_values() {
        assert_eq!(parse_check_mode(Some("never")), CheckMode::Never);
        assert_eq!(parse_check_mode(Some("NEVER")), CheckMode::Never);
        assert_eq!(parse_check_mode(Some("always")), CheckMode::Always);
        assert_eq!(parse_check_mode(Some("Daily")), CheckMode::Daily);
        assert_eq!(parse_check_mode(Some("  always ")), CheckMode::Always);
    }

    #[test]
    fn parse_check_mode_unknown_falls_back_to_daily() {
        assert_eq!(parse_check_mode(None), CheckMode::Daily);
        assert_eq!(parse_check_mode(Some("")), CheckMode::Daily);
        assert_eq!(parse_check_mode(Some("something-else")), CheckMode::Daily);
    }

    // ── parse_disabled_env ──

    #[test]
    fn parse_disabled_env_truthy() {
        assert!(parse_disabled_env(Some("1")));
        assert!(parse_disabled_env(Some("yes")));
        assert!(parse_disabled_env(Some("0"))); // any non-empty value disables
    }

    #[test]
    fn parse_disabled_env_empty_or_unset() {
        assert!(!parse_disabled_env(None));
        assert!(!parse_disabled_env(Some("")));
    }

    // ── parse_rfc3339_secs ──

    #[test]
    fn parse_rfc3339_known_timestamps() {
        assert_eq!(parse_rfc3339_secs("1970-01-01T00:00:00Z"), Some(0));
        // 2024-01-01T00:00:00Z = 1704067200
        assert_eq!(
            parse_rfc3339_secs("2024-01-01T00:00:00Z"),
            Some(1_704_067_200)
        );
        // 2024-02-29T12:34:56Z (leap day) = 1709210096
        assert_eq!(
            parse_rfc3339_secs("2024-02-29T12:34:56Z"),
            Some(1_709_210_096)
        );
    }

    #[test]
    fn parse_rfc3339_rejects_malformed() {
        assert_eq!(parse_rfc3339_secs(""), None);
        assert_eq!(parse_rfc3339_secs("2024-01-01"), None); // too short
        assert_eq!(parse_rfc3339_secs("2024-01-01T00:00:00"), None); // no Z
        assert_eq!(parse_rfc3339_secs("2024-13-01T00:00:00Z"), None); // bad month
        assert_eq!(parse_rfc3339_secs("2023-02-29T00:00:00Z"), None); // not a leap year
        assert_eq!(parse_rfc3339_secs("2024-01-01T25:00:00Z"), None); // bad hour
        assert_eq!(parse_rfc3339_secs("not-a-date-just-text"), None);
    }

    #[test]
    fn parse_rfc3339_rejects_leap_second_marker() {
        // We own the writer (rfc3339_now) which never emits :60. Accepting
        // 60 here would silently over-count by 1 second, so the parser
        // rejects it outright.
        assert_eq!(parse_rfc3339_secs("2024-06-30T23:59:60Z"), None);
    }
}
