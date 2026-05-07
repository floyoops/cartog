#!/usr/bin/env bash
set -euo pipefail

# Unit tests for ensure_indexed.sh
# Uses mocked cartog and install.sh to verify phase ordering and the
# install / self-update branches.
#
# Usage: bash skills/cartog/tests/test_ensure_indexed.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENSURE_SCRIPT="$SKILL_DIR/scripts/ensure_indexed.sh"
REAL_INSTALL="$SKILL_DIR/scripts/install.sh"

PASS=0
FAIL=0
TEST_DIR=""

# --- helpers ---

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin"
    export CARTOG_TEST_LOG="$TEST_DIR/commands.log"
    : > "$CARTOG_TEST_LOG"
    export CARTOG_LOCK_DIR="$TEST_DIR/rag-index.lock"
    export CARTOG_LOG_DIR="$TEST_DIR/log"
    # Default plugin.json fixture — tests can override via write_plugin_json.
    write_plugin_json "0.14.1"
    export CARTOG_PLUGIN_JSON="$TEST_DIR/plugin.json"
}

teardown() {
    local i=0
    while [ -d "${CARTOG_LOCK_DIR:-}" ] && [ "$i" -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    rmdir "${CARTOG_LOCK_DIR:-}" 2>/dev/null || true
    [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"
    unset CARTOG_PLUGIN_JSON
    unset CARTOG_LOG_DIR
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  FAIL: $label"
        echo "    expected NOT to contain: $needle"
        echo "    actual: $haystack"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    file not found: $path"
        FAIL=$((FAIL + 1))
    fi
}

write_plugin_json() {
    local version="$1"
    cat > "$TEST_DIR/plugin.json" <<JSON
{ "name": "cartog", "version": "$version" }
JSON
}

# Mock cartog: logs every invocation; supports --version, index, rag setup,
# rag index, and `self update`. self_update_exit lets us simulate failures.
create_mock_cartog() {
    local mock_version="${1:-0.14.1}"
    local rag_setup_exit="${2:-0}"
    local rag_setup_stderr="${3:-}"
    local self_update_exit="${4:-0}"
    cat > "$TEST_DIR/bin/cartog" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
    echo "cartog $mock_version"
    exit 0
fi
echo "\$@" >> "$CARTOG_TEST_LOG"
if [ "\$1" = "index" ]; then
    exit 0
elif [ "\$1" = "rag" ] && [ "\$2" = "setup" ]; then
    if [ -n "$rag_setup_stderr" ]; then echo "$rag_setup_stderr" >&2; fi
    exit $rag_setup_exit
elif [ "\$1" = "rag" ] && [ "\$2" = "index" ]; then
    sleep 0.1
    exit 0
elif [ "\$1" = "self" ] && [ "\$2" = "update" ]; then
    if [ "$self_update_exit" -ne 0 ]; then
        echo "self update mock failure" >&2
    else
        echo "cartog updated"
    fi
    exit $self_update_exit
fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"
}

# Replace install.sh in the skill scripts dir with a stub for the duration
# of one test. The stub creates a mock cartog binary on first run, simulating
# a successful bootstrap. Pass exit=non-zero to simulate install failure.
shadow_install_sh() {
    local exit_code="${1:-0}"
    local installed_version="${2:-0.14.1}"
    local install_log="$TEST_DIR/install.log"
    : > "$install_log"
    cp "$REAL_INSTALL" "$TEST_DIR/install.sh.bak"
    cat > "$REAL_INSTALL" <<STUB
#!/usr/bin/env bash
# Log args verbatim so tests can assert pinning behavior.
printf 'install.sh args=[%s] exit=$exit_code\n' "\$*" >> "$install_log"
if [ "$exit_code" -ne 0 ]; then
    echo "install.sh: simulated failure" >&2
    exit $exit_code
fi
cat > "$TEST_DIR/bin/cartog" <<INNER
#!/usr/bin/env bash
if [ "\\\$1" = "--version" ]; then echo "cartog $installed_version"; exit 0; fi
echo "\\\$@" >> "$CARTOG_TEST_LOG"
if [ "\\\$1" = "rag" ] && [ "\\\$2" = "index" ]; then sleep 0.1; fi
exit 0
INNER
chmod +x "$TEST_DIR/bin/cartog"
exit 0
STUB
    chmod +x "$REAL_INSTALL"
}

restore_install_sh() {
    if [ -f "$TEST_DIR/install.sh.bak" ]; then
        mv "$TEST_DIR/install.sh.bak" "$REAL_INSTALL"
    fi
}

run_ensure_indexed() {
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir"
    (
        # Hermetic PATH: only the test bin + minimal system core (for stat/date/sed/etc.).
        # Excluding $PATH prevents a developer-installed `cartog` (e.g. ~/.cargo/bin/cartog)
        # from leaking in and making "missing binary" tests pass spuriously.
        export PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOME="$TEST_DIR/home"
        mkdir -p "$HOME"
        cd "$workdir"
        bash "$ENSURE_SCRIPT" 2>&1
    )
}

# Wait until the background pipeline finishes so log assertions are stable.
wait_for_rag_index() {
    local i=0
    while ! grep -q '^rag index ' "$CARTOG_TEST_LOG" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    # Also wait for the lock to release so subsequent tests don't race.
    i=0
    while [ -d "${CARTOG_LOCK_DIR:-}" ] && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

# Read the background session log (stdout/stderr from the background pipeline).
session_log() {
    local log_file="${CARTOG_LOG_DIR:-}/session.log"
    [ -f "$log_file" ] && cat "$log_file" || true
}

# --- tests: indexing phases (versions in sync, no install/update path) ---

test_fresh_index_shows_building() {
    echo "TEST: fresh index (no .cartog.db) shows 'Building'"
    setup
    create_mock_cartog "0.14.1"
    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index
    assert_contains "shows 'Building'" "No cartog index found. Building..." "$output"
    teardown
}

test_existing_index_shows_updating() {
    echo "TEST: existing .cartog.db shows 'Updating'"
    setup
    create_mock_cartog "0.14.1"
    mkdir -p "$TEST_DIR/workdir"
    touch "$TEST_DIR/workdir/.cartog.db"
    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index
    assert_contains "shows 'Updating'" "Updating cartog index..." "$output"
    teardown
}

test_phase_order() {
    echo "TEST: commands run in correct order (foreground index, then background rag setup → rag index)"
    setup
    create_mock_cartog "0.14.1"

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    # Foreground: index runs first.
    local line1
    line1=$(sed -n '1p' "$CARTOG_TEST_LOG")
    assert_eq "foreground: cartog index ." "index ." "$line1"

    # Background pipeline runs rag setup before rag index. Their relative position
    # in CARTOG_TEST_LOG is what matters (same mock writes both serially).
    local setup_line index_line
    setup_line=$(grep -nx 'rag setup' "$CARTOG_TEST_LOG" | head -1 | cut -d: -f1)
    index_line=$(grep -nx 'rag index .' "$CARTOG_TEST_LOG" | head -1 | cut -d: -f1)
    if [ -n "$setup_line" ] && [ -n "$index_line" ] && [ "$setup_line" -lt "$index_line" ]; then
        echo "  PASS: background: rag setup before rag index"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: rag setup ($setup_line) should precede rag index ($index_line)"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_rag_setup_failure_continues() {
    echo "TEST: rag setup failure is logged but rag index still runs"
    setup
    create_mock_cartog "0.14.1" 1 "Error: model download failed"

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    local log
    log=$(session_log)
    assert_contains "log notes B2 failure" "B2 failed" "$log"
    if grep -qx 'rag index .' "$CARTOG_TEST_LOG"; then
        echo "  PASS: rag index still runs after rag setup failure"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: rag index did not run after rag setup failure"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_rag_setup_stderr_in_session_log() {
    echo "TEST: rag setup stderr is captured in session log (not foreground stdout)"
    setup
    create_mock_cartog "0.14.1" 1 "Error: disk full"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_not_contains "stderr NOT in foreground output" "Error: disk full" "$output"
    local log
    log=$(session_log)
    assert_contains "stderr captured in session log" "Error: disk full" "$log"
    teardown
}

test_session_log_created() {
    echo "TEST: session log directory and file are created"
    setup
    create_mock_cartog "0.14.1"

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    if [ -f "$CARTOG_LOG_DIR/session.log" ]; then
        echo "  PASS: session log file exists at $CARTOG_LOG_DIR/session.log"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: session log not found at $CARTOG_LOG_DIR/session.log"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_last_error_surfaces_next_session() {
    echo "TEST: last-error file from previous session is surfaced and cleared"
    setup
    create_mock_cartog "0.14.1"
    mkdir -p "$CARTOG_LOG_DIR"
    echo "previous failure detail" > "$CARTOG_LOG_DIR/last-error"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "surfaces previous error" "previous failure detail" "$output"
    assert_contains "shows error header" "Previous cartog background task failed" "$output"
    if [ ! -f "$CARTOG_LOG_DIR/last-error" ]; then
        echo "  PASS: last-error file cleared after surfacing"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: last-error file still exists after surfacing"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_background_failure_writes_last_error() {
    echo "TEST: background pipeline failure writes last-error file"
    setup
    # rag setup AND rag index both fail
    cat > "$TEST_DIR/bin/cartog" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "cartog 0.14.1"; exit 0; fi
echo "$@" >> "$CARTOG_TEST_LOG"
case "$1 $2" in
    "rag setup") echo "setup boom" >&2; exit 1 ;;
    "rag index") echo "index boom" >&2; exit 1 ;;
esac
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    if [ -f "$CARTOG_LOG_DIR/last-error" ]; then
        echo "  PASS: last-error file created on background failure"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: last-error file missing after background failure"
        FAIL=$((FAIL + 1))
    fi
    local last_error
    last_error=$(cat "$CARTOG_LOG_DIR/last-error" 2>/dev/null || echo "")
    assert_contains "last-error references session log" "session.log" "$last_error"
    teardown
}

test_background_rag_index() {
    echo "TEST: rag index runs in background (script returns before it finishes)"
    setup
    # Long-running rag index — script must return before it finishes.
    cat > "$TEST_DIR/bin/cartog" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "cartog 0.14.1"; exit 0; fi
echo "$@" >> "$CARTOG_TEST_LOG"
if [ "$1" = "rag" ] && [ "$2" = "index" ]; then sleep 3; fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    local start end elapsed
    start=$(date +%s)
    run_ensure_indexed > /dev/null
    end=$(date +%s)
    elapsed=$((end - start))

    if [ "$elapsed" -lt 3 ]; then
        echo "  PASS: script returned before background rag index finished (${elapsed}s < 3s)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: script blocked on rag index (${elapsed}s >= 3s)"
        FAIL=$((FAIL + 1))
    fi
    # Clean up: kill background rag index and release lock so teardown is fast.
    pkill -f "rag index" 2>/dev/null || true
    rmdir "${CARTOG_LOCK_DIR:-}" 2>/dev/null || true
    teardown
}

test_self_update_runs_in_background() {
    echo "TEST: self update no longer blocks foreground (runs in background pipeline)"
    setup
    write_plugin_json "0.14.1"
    # Slow self update — foreground must return before it finishes.
    cat > "$TEST_DIR/bin/cartog" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "cartog 0.14.0"; exit 0; fi
echo "$@" >> "$CARTOG_TEST_LOG"
if [ "$1" = "self" ] && [ "$2" = "update" ]; then sleep 3; echo "updated"; fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    local start end elapsed
    start=$(date +%s)
    run_ensure_indexed > /dev/null
    end=$(date +%s)
    elapsed=$((end - start))

    if [ "$elapsed" -lt 3 ]; then
        echo "  PASS: foreground returned before background self update (${elapsed}s < 3s)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: foreground blocked on self update (${elapsed}s >= 3s)"
        FAIL=$((FAIL + 1))
    fi
    pkill -f "self update" 2>/dev/null || true
    rmdir "${CARTOG_LOCK_DIR:-}" 2>/dev/null || true
    teardown
}

test_index_runs_in_foreground() {
    echo "TEST: cartog index is recorded before script returns (proves foreground)"
    setup
    create_mock_cartog "0.14.1"

    run_ensure_indexed > /dev/null
    # Do NOT call wait_for_rag_index — we want to see what was logged synchronously.
    # The index command should already be in the log at this point.
    if grep -qx 'index .' "$CARTOG_TEST_LOG"; then
        echo "  PASS: 'index .' present immediately after script returned"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: 'index .' missing from log right after return — index not foreground?"
        FAIL=$((FAIL + 1))
    fi

    wait_for_rag_index
    teardown
}

test_lock_prevents_concurrent_background_pipeline() {
    echo "TEST: lock prevents concurrent background pipeline (second run skips)"
    setup
    create_mock_cartog "0.14.1"
    mkdir "$CARTOG_LOCK_DIR"

    local output
    output=$(run_ensure_indexed)

    assert_contains "skips background pipeline" "background pipeline already running" "$output"
    # Only the foreground 'index .' should have been recorded — no rag setup or rag index.
    local line_count
    line_count=$(wc -l < "$CARTOG_TEST_LOG" | tr -d ' ')
    assert_eq "only foreground index logged (no background pipeline)" "1" "$line_count"
    rmdir "$CARTOG_LOCK_DIR" 2>/dev/null || true
    teardown
}

test_lock_cleaned_after_rag_index() {
    echo "TEST: lock directory is removed after rag index completes"
    setup
    create_mock_cartog "0.14.1"

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    if [ ! -d "$CARTOG_LOCK_DIR" ]; then
        echo "  PASS: lock directory cleaned up after completion"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: lock directory still exists after rag index finished"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_stale_lock_removed() {
    echo "TEST: stale lock (>1 hour) is removed and background pipeline proceeds"
    setup
    create_mock_cartog "0.14.1"

    mkdir "$CARTOG_LOCK_DIR"
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CARTOG_LOCK_DIR"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "detects stale lock" "Removing stale cartog background lock" "$output"
    assert_contains "starts background pipeline" "cartog background tasks started" "$output"
    if grep -qx 'rag index .' "$CARTOG_TEST_LOG"; then
        echo "  PASS: rag index runs after stale lock removal"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: rag index did not run after stale lock removal"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_output_messages() {
    echo "TEST: foreground output mentions background PID and index-ready status"
    setup
    create_mock_cartog "0.14.1"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "mentions background PID" "cartog background tasks started" "$output"
    assert_contains "mentions index ready" "cartog index ready" "$output"
    teardown
}

# --- tests: missing binary → install.sh ---

test_missing_binary_runs_install() {
    echo "TEST: missing cartog binary triggers install.sh pinned to PLUGIN_VERSION"
    setup
    write_plugin_json "0.14.1"
    shadow_install_sh 0 "0.14.1"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "succeeds after install" "0" "$rc"
    assert_file_exists "install.sh ran" "$TEST_DIR/install.log"
    assert_contains "announces install" "Installing via" "$output"
    assert_contains "install.sh pinned to plugin version" "args=[0.14.1]" "$(cat "$TEST_DIR/install.log")"
    local line1
    line1=$(sed -n '1p' "$CARTOG_TEST_LOG")
    assert_eq "indexing runs" "index ." "$line1"
    teardown
}

test_missing_binary_no_plugin_json_runs_install_unpinned() {
    echo "TEST: missing binary + no plugin.json runs install.sh with no version arg"
    setup
    rm -f "$TEST_DIR/plugin.json"
    shadow_install_sh 0 "0.14.1"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "succeeds after install" "0" "$rc"
    assert_contains "install.sh unpinned" "args=[]" "$(cat "$TEST_DIR/install.log")"
    teardown
}

test_missing_binary_install_failure_propagates() {
    echo "TEST: install.sh failure on missing binary exits 1 with stderr"
    setup
    shadow_install_sh 17

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    restore_install_sh

    assert_eq "exits non-zero" "1" "$rc"
    assert_contains "surfaces install error" "install.sh: simulated failure" "$output"
    assert_contains "summary line" "cartog install failed" "$output"
    # No indexing should have happened
    if [ -s "$CARTOG_TEST_LOG" ]; then
        echo "  FAIL: cartog commands ran despite install failure"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: no cartog commands ran after install failure"
        PASS=$((PASS + 1))
    fi
    teardown
}

# --- tests: outdated binary → cartog self update (>= 0.14.0) ---

test_outdated_modern_binary_self_updates() {
    echo "TEST: installed >= 0.14.0 but != plugin runs 'cartog self update' in background"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.14.0"  # outdated, but self update CLI exists

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index

    assert_eq "succeeds" "0" "$rc"
    # Self update announce now appears in the session log, NOT in foreground output.
    assert_not_contains "no self update announce in foreground" "Updating cartog 0.14.0" "$output"
    local log
    log=$(session_log)
    assert_contains "announces self update in log" "Updating cartog 0.14.0 → latest via 'cartog self update'" "$log"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: 'cartog self update' was invoked"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: 'cartog self update' was not invoked"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_self_update_failure_recorded_to_last_error() {
    echo "TEST: 'cartog self update' failure does NOT block foreground; recorded to last-error"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.14.0" 0 "" 2  # self update exits 2

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index

    # Foreground succeeds — index still runs because B1 is now async.
    assert_eq "foreground succeeds" "0" "$rc"
    if grep -qx 'index .' "$CARTOG_TEST_LOG"; then
        echo "  PASS: index ran in foreground despite background self update failure"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: index did not run"
        FAIL=$((FAIL + 1))
    fi
    # Failure recorded for next session.
    if [ -f "$CARTOG_LOG_DIR/last-error" ]; then
        echo "  PASS: last-error file written on background self update failure"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: last-error file missing"
        FAIL=$((FAIL + 1))
    fi
    local log
    log=$(session_log)
    assert_contains "log captures self update failure" "cartog self update failed (exit 2)" "$log"
    teardown
}

# --- tests: outdated binary < 0.14.0 → install.sh fallback ---

test_outdated_legacy_binary_uses_install_sh() {
    echo "TEST: installed < 0.14.0 reinstalls via install.sh in background"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.13.5"  # pre-self-update version
    shadow_install_sh 0 "0.14.1"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "succeeds" "0" "$rc"
    # Install announce is now in session log, not foreground.
    assert_not_contains "no install announce in foreground" "Updating cartog 0.13.5" "$output"
    local log
    log=$(session_log)
    assert_contains "log announces install fallback" "Updating cartog 0.13.5 → 0.14.1 via" "$log"
    assert_contains "log mentions pre-self-update" "(pre-self-update)" "$log"
    assert_file_exists "install.sh ran" "$TEST_DIR/install.log"
    assert_contains "install.sh pinned to plugin version" "args=[0.14.1]" "$(cat "$TEST_DIR/install.log")"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'cartog self update' was called on legacy binary"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'cartog self update' skipped on legacy binary"
        PASS=$((PASS + 1))
    fi
    teardown
}

test_outdated_legacy_install_failure_recorded() {
    echo "TEST: install.sh failure on legacy upgrade does NOT fail foreground; logged to last-error"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.13.5"
    shadow_install_sh 9

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "foreground succeeds" "0" "$rc"
    if [ -f "$CARTOG_LOG_DIR/last-error" ]; then
        echo "  PASS: last-error file written on background install failure"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: last-error file missing"
        FAIL=$((FAIL + 1))
    fi
    local log
    log=$(session_log)
    assert_contains "log captures install failure" "install.sh: simulated failure" "$log"
    teardown
}

# --- tests: in-sync binary skips install/update ---

test_synced_binary_skips_update() {
    echo "TEST: installed == plugin version skips install and self update"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.14.1"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_not_contains "no install announce in foreground" "Installing via" "$output"
    local log
    log=$(session_log)
    assert_not_contains "no update announce in log" "Updating cartog 0." "$log"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'cartog self update' ran when versions matched"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'cartog self update' skipped when versions matched"
        PASS=$((PASS + 1))
    fi
    teardown
}

test_newer_installed_triggers_background_update() {
    echo "TEST: installed > plugin version still triggers background self update (drift)"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.15.0"  # ahead of plugin

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    local log
    log=$(session_log)
    assert_contains "log announces drift update" "Updating cartog 0.15.0 → latest" "$log"
    teardown
}

test_no_plugin_json_modern_uptodate_skips() {
    echo "TEST: no plugin.json + modern binary already at latest skips update"
    setup
    rm -f "$TEST_DIR/plugin.json"
    # --check returns 0 (up to date), so we should not run self update.
    cat > "$TEST_DIR/bin/cartog" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "cartog 0.14.1"; exit 0; fi
echo "\$@" >> "$CARTOG_TEST_LOG"
if [ "\$1" = "self" ] && [ "\$2" = "update" ] && [ "\$3" = "--check" ]; then exit 0; fi
if [ "\$1" = "self" ] && [ "\$2" = "update" ]; then echo "should not run" >&2; exit 1; fi
if [ "\$1" = "rag" ] && [ "\$2" = "index" ]; then sleep 0.1; fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index

    assert_eq "succeeds" "0" "$rc"
    assert_not_contains "no update announce" "Updating cartog" "$output"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'self update' ran when --check said up to date"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'self update' skipped when --check said up to date"
        PASS=$((PASS + 1))
    fi
    teardown
}

test_no_plugin_json_modern_outdated_self_updates() {
    echo "TEST: no plugin.json + modern binary outdated runs self update in background"
    setup
    rm -f "$TEST_DIR/plugin.json"
    cat > "$TEST_DIR/bin/cartog" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "cartog 0.14.0"; exit 0; fi
echo "\$@" >> "$CARTOG_TEST_LOG"
if [ "\$1" = "self" ] && [ "\$2" = "update" ] && [ "\$3" = "--check" ]; then exit 1; fi
if [ "\$1" = "self" ] && [ "\$2" = "update" ]; then echo "updated to latest"; exit 0; fi
if [ "\$1" = "rag" ] && [ "\$2" = "index" ]; then sleep 0.1; fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index

    assert_eq "succeeds" "0" "$rc"
    local log
    log=$(session_log)
    assert_contains "log announces update to latest" "Updating cartog 0.14.0 → latest" "$log"
    assert_contains "log captures self update output" "updated to latest" "$log"
    teardown
}

test_no_plugin_json_legacy_uses_install_sh() {
    echo "TEST: no plugin.json + legacy binary (<0.14.0) reinstalls via install.sh in background"
    setup
    rm -f "$TEST_DIR/plugin.json"
    create_mock_cartog "0.13.5"
    shadow_install_sh 0 "0.14.1"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "succeeds" "0" "$rc"
    local log
    log=$(session_log)
    assert_contains "log announces install fallback" "Updating cartog 0.13.5 → latest via" "$log"
    assert_contains "log mentions pre-self-update" "(pre-self-update)" "$log"
    assert_file_exists "install.sh ran" "$TEST_DIR/install.log"
    teardown
}

test_no_plugin_json_check_network_error_skips() {
    echo "TEST: no plugin.json + --check network error skips update silently"
    setup
    rm -f "$TEST_DIR/plugin.json"
    cat > "$TEST_DIR/bin/cartog" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "cartog 0.14.0"; exit 0; fi
echo "\$@" >> "$CARTOG_TEST_LOG"
if [ "\$1" = "self" ] && [ "\$2" = "update" ] && [ "\$3" = "--check" ]; then exit 2; fi
if [ "\$1" = "self" ] && [ "\$2" = "update" ]; then echo "should not run" >&2; exit 1; fi
if [ "\$1" = "rag" ] && [ "\$2" = "index" ]; then sleep 0.1; fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index

    assert_eq "succeeds" "0" "$rc"
    assert_not_contains "no update announce" "Updating cartog" "$output"
    # Indexing should still run
    local line
    line=$(grep -x 'index .' "$CARTOG_TEST_LOG" || true)
    assert_eq "indexing still runs" "index ." "$line"
    teardown
}

# --- tests: .cartog.toml DB path resolution ---
#
# These tests inject `echo "DB_FILE=$DB_FILE"` right before phase 1 (the
# `cartog index .` line) so we can capture the resolved DB path without
# running the indexing phases.
run_ensure_indexed_print_db() {
    local workdir="$1"
    shift
    (
        export PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOME="$TEST_DIR/home"
        mkdir -p "$HOME"
        "$@"
        cd "$workdir"
        # Patch: insert echo just before "cartog index ." (phase 1)
        sed 's|^cartog index \.$|echo "DB_FILE=$DB_FILE"\nexit 0|' "$ENSURE_SCRIPT" | bash 2>&1
    )
}

test_toml_cwd_database_path() {
    echo "TEST: .cartog.toml in cwd sets DB_FILE from database.path"
    setup
    create_mock_cartog "0.14.1"
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir"
    cat > "$workdir/.cartog.toml" <<'TOML'
[database]
path = "/custom/my.db"
TOML

    local output
    output=$(run_ensure_indexed_print_db "$workdir")

    assert_contains "uses toml path" "DB_FILE=/custom/my.db" "$output"
    teardown
}

test_toml_git_root_database_path() {
    echo "TEST: .cartog.toml at git root sets DB_FILE"
    setup
    create_mock_cartog "0.14.1"
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir/subdir"

    cat > "$TEST_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
    echo "$workdir"; exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/git"

    cat > "$workdir/.cartog.toml" <<'TOML'
[database]
path = "/root-level/cartog.db"
TOML

    local output
    output=$(run_ensure_indexed_print_db "$workdir/subdir")

    assert_contains "uses git root toml" "DB_FILE=/root-level/cartog.db" "$output"
    teardown
}

test_toml_tilde_expansion() {
    echo "TEST: .cartog.toml path with ~/ expands to HOME"
    setup
    create_mock_cartog "0.14.1"
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir"
    cat > "$workdir/.cartog.toml" <<'TOML'
[database]
path = "~/projects/my.db"
TOML

    local output
    output=$(run_ensure_indexed_print_db "$workdir")

    assert_contains "tilde expanded" "DB_FILE=$TEST_DIR/home/projects/my.db" "$output"
    teardown
}

test_cartog_db_env_overrides_toml() {
    echo "TEST: CARTOG_DB env var overrides .cartog.toml"
    setup
    create_mock_cartog "0.14.1"
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir"
    cat > "$workdir/.cartog.toml" <<'TOML'
[database]
path = "/toml/path.db"
TOML

    local output
    output=$(run_ensure_indexed_print_db "$workdir" export CARTOG_DB="/env/override.db")

    assert_contains "env overrides toml" "DB_FILE=/env/override.db" "$output"
    teardown
}

test_no_toml_falls_back_to_git_root() {
    echo "TEST: no .cartog.toml falls back to git root"
    setup
    create_mock_cartog "0.14.1"
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir"

    cat > "$TEST_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
    echo "$workdir"; exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/git"

    local output
    output=$(run_ensure_indexed_print_db "$workdir")

    assert_contains "falls back to git root" "DB_FILE=$workdir/.cartog.db" "$output"
    teardown
}

# --- run all tests ---

echo "=== ensure_indexed.sh unit tests ==="
echo ""

test_fresh_index_shows_building
echo ""
test_existing_index_shows_updating
echo ""
test_phase_order
echo ""
test_index_runs_in_foreground
echo ""
test_rag_setup_failure_continues
echo ""
test_rag_setup_stderr_in_session_log
echo ""
test_session_log_created
echo ""
test_last_error_surfaces_next_session
echo ""
test_background_failure_writes_last_error
echo ""
test_background_rag_index
echo ""
test_self_update_runs_in_background
echo ""
test_lock_prevents_concurrent_background_pipeline
echo ""
test_lock_cleaned_after_rag_index
echo ""
test_stale_lock_removed
echo ""
test_output_messages
echo ""
test_missing_binary_runs_install
echo ""
test_missing_binary_no_plugin_json_runs_install_unpinned
echo ""
test_missing_binary_install_failure_propagates
echo ""
test_outdated_modern_binary_self_updates
echo ""
test_self_update_failure_recorded_to_last_error
echo ""
test_outdated_legacy_binary_uses_install_sh
echo ""
test_outdated_legacy_install_failure_recorded
echo ""
test_synced_binary_skips_update
echo ""
test_newer_installed_triggers_background_update
echo ""
test_no_plugin_json_modern_uptodate_skips
echo ""
test_no_plugin_json_modern_outdated_self_updates
echo ""
test_no_plugin_json_legacy_uses_install_sh
echo ""
test_no_plugin_json_check_network_error_skips
echo ""
test_toml_cwd_database_path
echo ""
test_toml_git_root_database_path
echo ""
test_toml_tilde_expansion
echo ""
test_cartog_db_env_overrides_toml
echo ""
test_no_toml_falls_back_to_git_root

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -eq 0 ] || exit 1
