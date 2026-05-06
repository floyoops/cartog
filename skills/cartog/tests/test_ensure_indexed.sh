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
        export PATH="$TEST_DIR/bin:$PATH"
        export HOME="$TEST_DIR/home"
        mkdir -p "$HOME"
        cd "$workdir"
        bash "$ENSURE_SCRIPT" 2>&1
    )
}

# Wait until the background `rag index` finishes so log assertions are stable.
wait_for_rag_index() {
    local i=0
    while ! grep -q '^rag index ' "$CARTOG_TEST_LOG" 2>/dev/null && [ "$i" -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    # Also wait for the lock to release so subsequent tests don't race.
    i=0
    while [ -d "${CARTOG_LOCK_DIR:-}" ] && [ "$i" -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
    done
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
    echo "TEST: commands run in correct order (index, rag setup, rag index)"
    setup
    create_mock_cartog "0.14.1"

    run_ensure_indexed > /dev/null
    wait_for_rag_index

    local line1 line2 line3
    line1=$(sed -n '1p' "$CARTOG_TEST_LOG")
    line2=$(sed -n '2p' "$CARTOG_TEST_LOG")
    line3=$(sed -n '3p' "$CARTOG_TEST_LOG")

    assert_eq "phase 1: cartog index ." "index ." "$line1"
    assert_eq "phase 2: cartog rag setup" "rag setup" "$line2"
    assert_eq "phase 3: cartog rag index ." "rag index ." "$line3"
    teardown
}

test_rag_setup_failure_continues() {
    echo "TEST: rag setup failure shows warning but continues to rag index"
    setup
    create_mock_cartog "0.14.1" 1 "Error: model download failed"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "shows warning" "Warning: cartog rag setup failed" "$output"
    local line3
    line3=$(sed -n '3p' "$CARTOG_TEST_LOG")
    assert_eq "rag index still runs" "rag index ." "$line3"
    teardown
}

test_rag_setup_stderr_visible() {
    echo "TEST: rag setup stderr is visible (not redirected to log file)"
    setup
    create_mock_cartog "0.14.1" 1 "Error: disk full"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "stderr visible in output" "Error: disk full" "$output"
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

test_lock_prevents_concurrent_rag_index() {
    echo "TEST: lock prevents concurrent rag index (second run skips)"
    setup
    create_mock_cartog "0.14.1"
    mkdir "$CARTOG_LOCK_DIR"

    local output
    output=$(run_ensure_indexed)

    assert_contains "skips rag index" "RAG embedding already running" "$output"
    local line_count
    line_count=$(wc -l < "$CARTOG_TEST_LOG" | tr -d ' ')
    assert_eq "only 2 commands logged (no rag index)" "2" "$line_count"
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
    echo "TEST: stale lock (>1 hour) is removed and rag index proceeds"
    setup
    create_mock_cartog "0.14.1"

    mkdir "$CARTOG_LOCK_DIR"
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$CARTOG_LOCK_DIR"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "detects stale lock" "Removing stale RAG lock" "$output"
    assert_contains "starts rag index" "RAG embedding started in background" "$output"
    local line3
    line3=$(sed -n '3p' "$CARTOG_TEST_LOG")
    assert_eq "rag index runs after stale lock removal" "rag index ." "$line3"
    teardown
}

test_output_messages() {
    echo "TEST: output includes RAG background PID and status message"
    setup
    create_mock_cartog "0.14.1"

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    assert_contains "mentions background PID" "RAG embedding started in background" "$output"
    assert_contains "mentions FTS5+reranker ready" "FTS5 + reranker" "$output"
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
    echo "TEST: installed >= 0.14.0 but != plugin runs 'cartog self update'"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.14.0"  # outdated, but self update CLI exists

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index

    assert_eq "succeeds" "0" "$rc"
    assert_contains "announces self update to latest" "Updating cartog 0.14.0 → latest via 'cartog self update'" "$output"
    assert_contains "self update output" "cartog updated" "$output"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  PASS: 'cartog self update' was invoked"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: 'cartog self update' was not invoked"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_self_update_failure_propagates() {
    echo "TEST: 'cartog self update' failure exits 1 with stderr surfaced"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.14.0" 0 "" 2  # self update exits 2

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?

    assert_eq "exits non-zero" "1" "$rc"
    assert_contains "summary line" "cartog self update failed (exit 2)" "$output"
    assert_contains "surfaces stderr" "self update mock failure" "$output"
    if grep -q '^index ' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: index ran despite self update failure"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: index did not run after self update failure"
        PASS=$((PASS + 1))
    fi
    teardown
}

# --- tests: outdated binary < 0.14.0 → install.sh fallback ---

test_outdated_legacy_binary_uses_install_sh() {
    echo "TEST: installed < 0.14.0 (no self update CLI) reinstalls via install.sh"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.13.5"  # pre-self-update version
    shadow_install_sh 0 "0.14.1"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "succeeds" "0" "$rc"
    assert_contains "announces install fallback" "Updating cartog 0.13.5 → 0.14.1 via" "$output"
    assert_contains "mentions pre-self-update" "(pre-self-update)" "$output"
    assert_file_exists "install.sh ran" "$TEST_DIR/install.log"
    assert_contains "install.sh pinned to plugin version" "args=[0.14.1]" "$(cat "$TEST_DIR/install.log")"
    # 'cartog self update' must NOT have been called
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'cartog self update' was called on legacy binary"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'cartog self update' skipped on legacy binary"
        PASS=$((PASS + 1))
    fi
    teardown
}

test_outdated_legacy_install_failure_propagates() {
    echo "TEST: install.sh failure on legacy upgrade exits 1"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.13.5"
    shadow_install_sh 9

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    restore_install_sh

    assert_eq "exits non-zero" "1" "$rc"
    assert_contains "surfaces install error" "install.sh: simulated failure" "$output"
    assert_contains "summary line" "cartog install failed" "$output"
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

    assert_not_contains "no install announce" "Installing via" "$output"
    assert_not_contains "no update announce" "Updating cartog 0." "$output"
    if grep -qx 'self update' "$CARTOG_TEST_LOG"; then
        echo "  FAIL: 'cartog self update' ran when versions matched"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: 'cartog self update' skipped when versions matched"
        PASS=$((PASS + 1))
    fi
    teardown
}

test_newer_installed_skips_update() {
    echo "TEST: installed > plugin version still skips update (different == plugin only triggers)"
    setup
    write_plugin_json "0.14.1"
    create_mock_cartog "0.15.0"  # ahead of plugin

    local output
    output=$(run_ensure_indexed)
    wait_for_rag_index

    # We trigger only on != plugin. Installed > plugin is a "drift" too — the
    # current design DOES try to self update in that case (since 0.15.0 >= 0.14.0).
    # `cartog self update` only goes to latest, so the announce says "→ latest".
    assert_contains "announces self update on drift" "Updating cartog 0.15.0 → latest" "$output"
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
    echo "TEST: no plugin.json + modern binary outdated runs self update"
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
    assert_contains "announces update to latest" "Updating cartog 0.14.0 → latest" "$output"
    assert_contains "self update output" "updated to latest" "$output"
    teardown
}

test_no_plugin_json_legacy_uses_install_sh() {
    echo "TEST: no plugin.json + legacy binary (<0.14.0) reinstalls via install.sh"
    setup
    rm -f "$TEST_DIR/plugin.json"
    create_mock_cartog "0.13.5"
    shadow_install_sh 0 "0.14.1"

    local output rc
    output=$(run_ensure_indexed) && rc=0 || rc=$?
    wait_for_rag_index
    restore_install_sh

    assert_eq "succeeds" "0" "$rc"
    assert_contains "announces install fallback" "Updating cartog 0.13.5 → latest via" "$output"
    assert_contains "mentions pre-self-update" "(pre-self-update)" "$output"
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
        export PATH="$TEST_DIR/bin:$PATH"
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
test_rag_setup_failure_continues
echo ""
test_rag_setup_stderr_visible
echo ""
test_background_rag_index
echo ""
test_lock_prevents_concurrent_rag_index
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
test_self_update_failure_propagates
echo ""
test_outdated_legacy_binary_uses_install_sh
echo ""
test_outdated_legacy_install_failure_propagates
echo ""
test_synced_binary_skips_update
echo ""
test_newer_installed_skips_update
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
