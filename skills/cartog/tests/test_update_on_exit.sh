#!/usr/bin/env bash
set -euo pipefail

# Unit tests for update_on_exit.sh (SessionEnd hook).
# Mirrors the mock setup of test_ensure_indexed.sh.
#
# Usage: bash skills/cartog/tests/test_update_on_exit.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UPDATE_SCRIPT="$SKILL_DIR/scripts/update_on_exit.sh"
REAL_INSTALL="$SKILL_DIR/scripts/install.sh"

PASS=0
FAIL=0
TEST_DIR=""

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin"
    export CARTOG_TEST_LOG="$TEST_DIR/commands.log"
    : > "$CARTOG_TEST_LOG"
    export CARTOG_LOG_DIR="$TEST_DIR/log"
    export CARTOG_LOCK_DIR="$TEST_DIR/rag-index.lock"
    export PEER_WAIT_SECS=1   # speed up peer-wait tests
    # Override the platform state dir so peer_alive() reads our fixtures.
    export HOME="$TEST_DIR/home"
    export XDG_STATE_HOME="$TEST_DIR/xdg_state"
    mkdir -p "$HOME" "$XDG_STATE_HOME"
    write_plugin_json "0.14.3"
    export CARTOG_PLUGIN_JSON="$TEST_DIR/plugin.json"
}

teardown() {
    rmdir "${CARTOG_LOCK_DIR:-}" 2>/dev/null || true
    [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"
    unset CARTOG_PLUGIN_JSON CARTOG_LOG_DIR CARTOG_TEST_LOG CARTOG_LOCK_DIR \
          PEER_WAIT_SECS XDG_STATE_HOME
}

# Resolve the state dir the same way update_on_exit.sh does, then write a
# PID file there. Use the current shell's PID — it's guaranteed live.
write_serve_pid_file() {
    local pid="${1:-$$}"
    local state_dir
    case "$(uname -s)" in
        Darwin) state_dir="$HOME/Library/Application Support/io.cartog.cartog" ;;
        Linux)  state_dir="$XDG_STATE_HOME/cartog" ;;
        *)      return 1 ;;
    esac
    mkdir -p "$state_dir"
    printf '%s\n' "$pid" > "$state_dir/serve.pid"
    printf '%s\n' "$state_dir/serve.pid"
}

# Pick a PID we know is dead: spawn a noop subshell and wait. PID is reused
# eventually but stays free for ~milliseconds, plenty for a test.
dead_pid() {
    ( exit 0 ) & local p=$!; wait "$p" 2>/dev/null
    printf '%s\n' "$p"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"; PASS=$((PASS + 1))
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
        echo "  PASS: $label"; PASS=$((PASS + 1))
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
        echo "  PASS: $label"; PASS=$((PASS + 1))
    fi
}

write_plugin_json() {
    local version="$1"
    cat > "$TEST_DIR/plugin.json" <<JSON
{ "name": "cartog", "version": "$version" }
JSON
}

# Mock cartog supporting --version, self update --check, self update.
# Args: version, self_update_exit, check_exit (peer-running simulation).
create_mock_cartog() {
    local mock_version="${1:-0.14.1}"
    local self_update_exit="${2:-0}"
    local check_exit="${3:-0}"
    cat > "$TEST_DIR/bin/cartog" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
    echo "cartog $mock_version"
    exit 0
fi
echo "\$@" >> "$CARTOG_TEST_LOG"
if [ "\$1" = "self" ] && [ "\$2" = "update" ] && [ "\$3" = "--check" ]; then
    exit $check_exit
fi
if [ "\$1" = "self" ] && [ "\$2" = "update" ]; then
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

shadow_install_sh() {
    local exit_code="${1:-0}"
    local install_log="$TEST_DIR/install.log"
    : > "$install_log"
    cp "$REAL_INSTALL" "$TEST_DIR/install.sh.bak"
    cat > "$REAL_INSTALL" <<STUB
#!/usr/bin/env bash
printf 'install.sh args=[%s] exit=$exit_code\n' "\$*" >> "$install_log"
if [ "$exit_code" -ne 0 ]; then
    echo "install.sh: simulated failure" >&2
    exit $exit_code
fi
exit 0
STUB
    chmod +x "$REAL_INSTALL"
}

restore_install_sh() {
    [ -f "$TEST_DIR/install.sh.bak" ] && mv "$TEST_DIR/install.sh.bak" "$REAL_INSTALL"
}

run_update_on_exit() {
    (
        export PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        # HOME and XDG_STATE_HOME are already exported by setup().
        bash "$UPDATE_SCRIPT" 2>&1
    )
}

session_log() {
    local f="${CARTOG_LOG_DIR:-}/session.log"
    [ -f "$f" ] && cat "$f" || true
}

# --- tests ---

test_synced_binary_noop() {
    echo "TEST: installed == plugin version is a noop (no self update call)"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.3"

    run_update_on_exit > /dev/null

    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'self update' ran when versions matched"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'self update' skipped when versions matched"; PASS=$((PASS + 1))
    fi
    teardown
}

test_modern_outdated_runs_self_update() {
    echo "TEST: modern binary (>=0.14.0) outdated runs 'cartog self update'"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2"

    run_update_on_exit > /dev/null

    local log
    log=$(session_log)
    assert_contains "log announces update" "Updating cartog 0.14.2 → 0.14.3 via 'cartog self update'" "$log"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: 'self update' invoked"; PASS=$((PASS + 1))
    else
        echo "  FAIL: 'self update' not invoked"; FAIL=$((FAIL + 1))
    fi
    teardown
}

test_self_update_failure_recorded() {
    echo "TEST: self update failure writes last-error and logs exit code"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2" 6   # exit 6 = PEER_RUNNING

    run_update_on_exit > /dev/null

    if [ -f "$CARTOG_LOG_DIR/last-error" ]; then
        echo "  PASS: last-error file written"; PASS=$((PASS + 1))
    else
        echo "  FAIL: last-error file missing"; FAIL=$((FAIL + 1))
    fi
    local log
    log=$(session_log)
    assert_contains "log captures exit code" "cartog self update failed (exit 6)" "$log"
    teardown
}

test_legacy_binary_uses_install_sh() {
    echo "TEST: pre-self-update binary (<0.14.0) routes through install.sh"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.13.5"
    shadow_install_sh 0

    run_update_on_exit > /dev/null
    restore_install_sh

    local log
    log=$(session_log)
    assert_contains "log announces install fallback" "Updating cartog 0.13.5 → 0.14.3 via install.sh (pre-self-update)" "$log"
    if [ -f "$TEST_DIR/install.log" ]; then
        echo "  PASS: install.sh invoked"; PASS=$((PASS + 1))
    else
        echo "  FAIL: install.sh not invoked"; FAIL=$((FAIL + 1))
    fi
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'self update' called on legacy binary"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'self update' skipped on legacy binary"; PASS=$((PASS + 1))
    fi
    teardown
}

test_missing_binary_is_noop() {
    echo "TEST: missing cartog binary exits cleanly without touching anything"
    setup
    # No mock cartog created; PATH points to empty bin dir.

    local rc=0
    run_update_on_exit > /dev/null || rc=$?

    assert_eq "exits 0 silently" "0" "$rc"
    if [ -s "$CARTOG_TEST_LOG" ]; then
        echo "  FAIL: cartog commands logged when binary missing"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: no cartog commands run when binary missing"; PASS=$((PASS + 1))
    fi
    teardown
}

test_no_plugin_json_proceeds_to_update() {
    echo "TEST: missing plugin.json — script falls through to self update"
    setup
    rm -f "$TEST_DIR/plugin.json"
    create_mock_cartog "0.14.0"

    run_update_on_exit > /dev/null

    # Without PLUGIN_VERSION, version-equality short-circuit can't fire,
    # so we fall through to wait_for_peer_exit + self update.
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: self update invoked when plugin.json absent and binary outdated"; PASS=$((PASS + 1))
    else
        echo "  FAIL: self update not invoked"; FAIL=$((FAIL + 1))
    fi
    teardown
}

# --- C1: peer detection via PID files (no network, no cartog invocation) ---

test_peer_wait_proceeds_when_no_pid_file() {
    echo "TEST: wait_for_peer_exit returns without polling when no serve.pid exists"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2"
    # PEER_WAIT_SECS large enough that polling would be obvious. We just need to
    # prove the peer-wait loop didn't block — exact subsecond timing is too
    # noisy on cold macOS bash, so we assert "well under PEER_WAIT_SECS".
    export PEER_WAIT_SECS=20
    # No write_serve_pid_file — state dir has no PID files.

    local start end elapsed
    start=$(date +%s)
    run_update_on_exit > /dev/null
    end=$(date +%s)
    elapsed=$((end - start))

    if [ "$elapsed" -lt 10 ]; then
        echo "  PASS: returned in ${elapsed}s (no peer → no full PEER_WAIT_SECS=20 wait)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: blocked ${elapsed}s — peer-wait loop polled despite no PID file"; FAIL=$((FAIL + 1))
    fi
    teardown
}

test_peer_wait_proceeds_when_pid_is_dead() {
    echo "TEST: wait_for_peer_exit ignores stale PID files (process not running)"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2"
    write_serve_pid_file "$(dead_pid)" >/dev/null
    export PEER_WAIT_SECS=20

    local start end elapsed
    start=$(date +%s)
    run_update_on_exit > /dev/null
    end=$(date +%s)
    elapsed=$((end - start))

    if [ "$elapsed" -lt 10 ]; then
        echo "  PASS: returned in ${elapsed}s (dead PID treated as no peer)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: blocked ${elapsed}s on dead peer"; FAIL=$((FAIL + 1))
    fi
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: self update ran (dead peer doesn't block)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: self update did not run"; FAIL=$((FAIL + 1))
    fi
    teardown
}

test_peer_wait_polls_until_pid_disappears() {
    echo "TEST: wait_for_peer_exit polls until live PID file is removed"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2"
    local pid_file
    pid_file="$(write_serve_pid_file "$$")"   # our own PID — live
    export PEER_WAIT_SECS=10

    # Remove the PID file after 2s so the loop notices the peer is gone.
    ( sleep 2; rm -f "$pid_file" ) &
    local cleaner=$!

    local start end elapsed
    start=$(date +%s)
    run_update_on_exit > /dev/null
    end=$(date +%s)
    elapsed=$((end - start))
    wait "$cleaner" 2>/dev/null || true

    # We polled at least once (peer was alive). Tolerate macOS bash startup
    # noise: lower bound 2s (the cleaner sleep), upper bound 8s.
    if [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 8 ]; then
        echo "  PASS: waited ${elapsed}s (peer cleared at 2s, within wait window)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: elapsed ${elapsed}s, expected 2-8s"; FAIL=$((FAIL + 1))
    fi
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: self update ran after peer cleared"; PASS=$((PASS + 1))
    else
        echo "  FAIL: self update never ran"; FAIL=$((FAIL + 1))
    fi
    teardown
}

# --- C2: RAG pipeline lock coordination ---

test_skips_update_when_rag_pipeline_running() {
    echo "TEST: update is skipped when RAG pipeline lock is recent (<1h old)"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2"
    mkdir -p "$CARTOG_LOCK_DIR"   # fresh lock — pipeline "running"

    run_update_on_exit > /dev/null

    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: self update ran while RAG pipeline lock was active"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: update skipped while RAG pipeline lock active"; PASS=$((PASS + 1))
    fi
    local log
    log=$(session_log)
    assert_contains "log explains skip" "RAG pipeline still running" "$log"
    teardown
}

test_proceeds_when_rag_lock_is_stale() {
    echo "TEST: update proceeds when RAG lock is older than 1h (stale)"
    setup
    write_plugin_json "0.14.3"
    create_mock_cartog "0.14.2"
    mkdir -p "$CARTOG_LOCK_DIR"
    # Backdate to 2h ago — older than the 1h staleness threshold.
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CARTOG_LOCK_DIR"

    run_update_on_exit > /dev/null

    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: self update ran (stale RAG lock ignored)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: self update did not run despite stale RAG lock"; FAIL=$((FAIL + 1))
    fi
    teardown
}

# --- run ---

echo "=== update_on_exit.sh unit tests ==="
echo ""

test_synced_binary_noop
echo ""
test_modern_outdated_runs_self_update
echo ""
test_self_update_failure_recorded
echo ""
test_legacy_binary_uses_install_sh
echo ""
test_missing_binary_is_noop
echo ""
test_no_plugin_json_proceeds_to_update
echo ""
test_peer_wait_proceeds_when_no_pid_file
echo ""
test_peer_wait_proceeds_when_pid_is_dead
echo ""
test_peer_wait_polls_until_pid_disappears
echo ""
test_skips_update_when_rag_pipeline_running
echo ""
test_proceeds_when_rag_lock_is_stale

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -eq 0 ] || exit 1
