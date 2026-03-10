#!/usr/bin/env bash
set -euo pipefail

# Unit tests for ensure_indexed.sh
# Uses mocked cartog commands to verify phase ordering and behavior.
#
# Usage: bash skills/cartog/tests/test_ensure_indexed.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENSURE_SCRIPT="$SKILL_DIR/scripts/ensure_indexed.sh"

PASS=0
FAIL=0
TEST_DIR=""

# --- helpers ---

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin"
    # log file tracks command invocations in order
    export CARTOG_TEST_LOG="$TEST_DIR/commands.log"
    : > "$CARTOG_TEST_LOG"
    # Clean up lock from any previous test
    rmdir /tmp/cartog-rag-index.lock 2>/dev/null || true
}

teardown() {
    rmdir /tmp/cartog-rag-index.lock 2>/dev/null || true
    [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"
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

# Create a mock cartog binary that logs invocations
create_mock_cartog() {
    local exit_rag_setup="${1:-0}"
    local rag_setup_stderr="${2:-}"
    cat > "$TEST_DIR/bin/cartog" <<MOCK
#!/usr/bin/env bash
echo "\$@" >> "$CARTOG_TEST_LOG"

# Simulate different subcommands
if [ "\$1" = "index" ]; then
    exit 0
elif [ "\$1" = "rag" ] && [ "\$2" = "setup" ]; then
    if [ -n "$rag_setup_stderr" ]; then
        echo "$rag_setup_stderr" >&2
    fi
    exit $exit_rag_setup
elif [ "\$1" = "rag" ] && [ "\$2" = "index" ]; then
    sleep 0.1
    exit 0
fi
MOCK
    chmod +x "$TEST_DIR/bin/cartog"
}

# Run ensure_indexed.sh with mocked cartog, in a temp workdir
run_ensure_indexed() {
    local workdir="$TEST_DIR/workdir"
    mkdir -p "$workdir"
    (
        export PATH="$TEST_DIR/bin:$PATH"
        cd "$workdir"
        bash "$ENSURE_SCRIPT" 2>&1
    )
}

# --- tests ---

test_fresh_index_shows_building() {
    echo "TEST: fresh index (no .cartog.db) shows 'Building'"
    setup
    create_mock_cartog

    local output
    output=$(run_ensure_indexed)

    assert_contains "shows 'Building'" "No cartog index found. Building..." "$output"
    teardown
}

test_existing_index_shows_updating() {
    echo "TEST: existing .cartog.db shows 'Updating'"
    setup
    create_mock_cartog
    touch "$TEST_DIR/workdir/.cartog.db" 2>/dev/null || { mkdir -p "$TEST_DIR/workdir" && touch "$TEST_DIR/workdir/.cartog.db"; }

    local output
    output=$(run_ensure_indexed)

    assert_contains "shows 'Updating'" "Updating cartog index..." "$output"
    teardown
}

test_phase_order() {
    echo "TEST: commands run in correct order (index, rag setup, rag index)"
    setup
    create_mock_cartog

    run_ensure_indexed > /dev/null
    # Wait briefly for background process to log
    sleep 0.3

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
    echo "TEST: rag setup failure shows warning with log path but continues to rag index"
    setup
    create_mock_cartog 1 "Error: model download failed"

    local output
    output=$(run_ensure_indexed)
    sleep 0.3

    assert_contains "shows warning" "Warning: cartog rag setup failed" "$output"
    assert_contains "mentions log path" "log:" "$output"
    # rag index should still run in background
    local line3
    line3=$(sed -n '3p' "$CARTOG_TEST_LOG")
    assert_eq "rag index still runs" "rag index ." "$line3"
    teardown
}

test_rag_setup_stderr_logged() {
    echo "TEST: rag setup stderr is captured to log file (not suppressed)"
    setup
    create_mock_cartog 1 "Error: disk full"

    local output
    output=$(run_ensure_indexed)

    # Extract log path from output
    local log_path
    log_path=$(echo "$output" | grep -oE '/tmp/cartog-rag-setup-[0-9]+\.log')
    if [ -n "$log_path" ] && [ -f "$log_path" ]; then
        local log_content
        log_content=$(cat "$log_path")
        assert_contains "stderr captured in log" "Error: disk full" "$log_content"
        rm -f "$log_path"
    else
        echo "  FAIL: rag setup log file not found"
        echo "    output: $output"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_background_rag_index() {
    echo "TEST: rag index runs in background (script returns before it finishes)"
    setup
    # Make rag index take longer
    cat > "$TEST_DIR/bin/cartog" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$CARTOG_TEST_LOG"
if [ "$1" = "rag" ] && [ "$2" = "index" ]; then
    sleep 2
    exit 0
fi
MOCK
    chmod +x "$TEST_DIR/bin/cartog"

    local start end elapsed
    start=$(date +%s)
    run_ensure_indexed > /dev/null
    end=$(date +%s)
    elapsed=$((end - start))

    # Script should return in < 2s (rag index sleeps 2s in background)
    if [ "$elapsed" -lt 2 ]; then
        echo "  PASS: script returned before background rag index finished (${elapsed}s < 2s)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: script blocked on rag index (${elapsed}s >= 2s)"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

test_lock_prevents_concurrent_rag_index() {
    echo "TEST: lock prevents concurrent rag index (second run skips)"
    setup
    create_mock_cartog

    # Pre-create the lock directory to simulate an already-running rag index
    mkdir /tmp/cartog-rag-index.lock

    local output
    output=$(run_ensure_indexed)
    sleep 0.3

    assert_contains "skips rag index" "RAG embedding already running" "$output"
    # Only index + rag setup should have run (no rag index)
    local line_count
    line_count=$(wc -l < "$CARTOG_TEST_LOG" | tr -d ' ')
    assert_eq "only 2 commands logged (no rag index)" "2" "$line_count"
    teardown
}

test_lock_cleaned_after_rag_index() {
    echo "TEST: lock directory is removed after rag index completes"
    setup
    create_mock_cartog

    run_ensure_indexed > /dev/null
    # Wait for background rag index to finish (mock sleeps 0.1s)
    sleep 0.5

    if [ ! -d /tmp/cartog-rag-index.lock ]; then
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
    create_mock_cartog

    # Create a lock directory and backdate it to 2 hours ago
    mkdir /tmp/cartog-rag-index.lock
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" /tmp/cartog-rag-index.lock

    local output
    output=$(run_ensure_indexed)
    sleep 0.3

    assert_contains "detects stale lock" "Removing stale RAG lock" "$output"
    assert_contains "starts rag index" "RAG embedding started in background" "$output"
    # All 3 phases should have run
    local line3
    line3=$(sed -n '3p' "$CARTOG_TEST_LOG")
    assert_eq "rag index runs after stale lock removal" "rag index ." "$line3"
    teardown
}

test_output_messages() {
    echo "TEST: output includes RAG background PID and status message"
    setup
    create_mock_cartog

    local output
    output=$(run_ensure_indexed)

    assert_contains "mentions background PID" "RAG embedding started in background" "$output"
    assert_contains "mentions FTS5+reranker ready" "FTS5 + reranker" "$output"
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
test_rag_setup_stderr_logged
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
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -eq 0 ] || exit 1
