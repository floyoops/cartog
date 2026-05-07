#!/usr/bin/env bash
set -euo pipefail

# SessionEnd hook: bring the cartog binary in sync with the plugin's pinned
# version. Runs after MCP shuts down so `cartog self update` can replace the
# binary without hitting its peer-running guard.
#
# Why this is a SessionEnd hook (not SessionStart):
#   `cartog serve` is launched by the Claude Code MCP layer at session start
#   in parallel with this plugin's hooks. `cartog self update` refuses to run
#   while a peer is alive (exit code 6). Updating at session end avoids the
#   race. Cost: a freshly released patch lands on the *next* session, not the
#   current one. Acceptable trade.
#
# Failure modes are written to ~/.cache/cartog/last-error and surfaced by
# ensure_indexed.sh on the next session start.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."

# Must match LOCK_DIR in ensure_indexed.sh — we coordinate on this path so an
# update doesn't swap the binary while a long-running RAG pipeline (started by
# a sibling SessionStart) is still using it.
LOCK_DIR="${CARTOG_LOCK_DIR:-/tmp/cartog-rag-index.lock}"

PLUGIN_JSON="${CARTOG_PLUGIN_JSON:-${SCRIPT_DIR}/../../../.claude-plugin/plugin.json}"
PLUGIN_VERSION="$( { sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" 2>/dev/null || true; } | head -n 1)"

SESSION_LOG_DIR="${CARTOG_LOG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/cartog}"
if ! mkdir -p "$SESSION_LOG_DIR" 2>/dev/null; then
    SESSION_LOG_DIR="/tmp"
fi
SESSION_LOG="$SESSION_LOG_DIR/session.log"
LAST_ERROR_FILE="$SESSION_LOG_DIR/last-error"

# Bail quietly if cartog isn't installed yet — there's nothing to update.
command -v cartog >/dev/null 2>&1 || exit 0

# Semver compare: returns 0 iff $1 > $2 component-wise (pre-release suffix stripped).
version_gt() {
    local IFS=.
    local -a a b
    read -ra a <<< "${1%%-*}"
    read -ra b <<< "${2%%-*}"
    local i
    for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
        local ai="${a[i]:-0}" bi="${b[i]:-0}"
        if [ "$ai" -gt "$bi" ] 2>/dev/null; then return 0; fi
        if [ "$ai" -lt "$bi" ] 2>/dev/null; then return 1; fi
    done
    return 1
}

# Resolve cartog's state directory the same way the binary does
# (crates/cartog/src/state.rs::default_state_dir): platform-specific via
# directories::ProjectDirs("io", "cartog", "cartog"). The bash equivalent:
#   macOS:   $HOME/Library/Application Support/io.cartog.cartog
#   Linux:   $XDG_STATE_HOME/cartog (else $HOME/.local/state/cartog)
#   Windows: not supported by these shell hooks
cartog_state_dir() {
    case "$(uname -s)" in
        Darwin) printf '%s\n' "$HOME/Library/Application Support/io.cartog.cartog" ;;
        Linux)  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/cartog" ;;
        *)      return 1 ;;
    esac
}

# Returns 0 if any cartog peer (e.g. `cartog serve`) is alive. Reads the same
# *.pid files that `cartog self update` consults via find_active_locks. Pure
# bash — no network, no fork to cartog itself.
peer_alive() {
    local dir
    dir="$(cartog_state_dir)" || return 1
    [ -d "$dir" ] || return 1
    local pid_file pid
    for pid_file in "$dir"/*.pid; do
        [ -f "$pid_file" ] || continue
        pid="$(head -n1 "$pid_file" 2>/dev/null | tr -dc '0-9')"
        [ -n "$pid" ] || continue
        # kill -0 succeeds iff the process exists and we have signal permission.
        # That's enough for a liveness check — we don't actually signal it.
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# Poll for peer exit before invoking `cartog self update` (which refuses with
# exit 6 while a peer is alive). Claude Code's docs don't pin down whether
# SessionEnd fires before or after MCP shutdown, so we self-heal both timings.
wait_for_peer_exit() {
    local timeout="${PEER_WAIT_SECS:-5}"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        peer_alive || return 0
        sleep 1
        i=$((i + 1))
    done
    return 0
}

# Returns 0 if a RAG pipeline (started by ensure_indexed.sh) is currently
# running. We refuse to update during that window — swapping the binary would
# leave the in-flight `cartog rag index` running on an unlinked inode while
# new invocations use the new version, risking embedding-format-version drift.
rag_pipeline_running() {
    [ -d "$LOCK_DIR" ] || return 1
    # The lock dir alone isn't enough — it can be stale if a previous session
    # crashed without removing it. ensure_indexed.sh treats >1h as stale; we
    # mirror that conservatively: only consider it running if it's recent.
    local lock_mtime now age
    lock_mtime="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)"
    case "$lock_mtime" in ''|*[!0-9]*) lock_mtime=0 ;; esac
    now="$(date +%s)"
    age=$((now - lock_mtime))
    [ "$age" -lt 3600 ]
}

run_update() {
    local installed
    installed="$(cartog --version 2>/dev/null | head -n 1 | sed -E 's/^cartog ([^ ]+).*/\1/')"
    [ -n "$installed" ] || return 0

    if [ -n "$PLUGIN_VERSION" ] && [ "$installed" = "$PLUGIN_VERSION" ]; then
        return 0
    fi

    if rag_pipeline_running; then
        echo "Skipping update: RAG pipeline still running (lock: $LOCK_DIR). Will retry next session."
        return 0
    fi

    # Pre-self-update binaries (<0.14.0) don't have `cartog self update` —
    # use install.sh, which can replace the binary even with a peer alive
    # (no peer-running guard there).
    if version_gt "0.14.0" "$installed"; then
        echo "Updating cartog $installed → ${PLUGIN_VERSION:-latest} via install.sh (pre-self-update)..."
        if ! bash "$SCRIPT_DIR/install.sh" ${PLUGIN_VERSION:+"$PLUGIN_VERSION"}; then
            echo "install.sh failed."
            return 1
        fi
        return 0
    fi

    # Modern binary path: wait for peer exit (best-effort), then self update.
    wait_for_peer_exit

    echo "Updating cartog $installed → ${PLUGIN_VERSION:-latest} via 'cartog self update'..."
    local update_output update_rc
    update_output="$(cartog self update 2>&1)" && update_rc=0 || update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
        echo "cartog self update failed (exit $update_rc):"
        printf '%s\n' "$update_output"
        return 1
    fi
    printf '%s\n' "$update_output"
    return 0
}

{
    echo "=== cartog session-end update $(date '+%Y-%m-%d %H:%M:%S') ==="
    if ! run_update; then
        printf 'See %s for details (session-end update failed).\n' "$SESSION_LOG" > "$LAST_ERROR_FILE"
        echo "=== session-end update exit 1 ==="
        exit 0
    fi
    echo "=== session-end update exit 0 ==="
} >> "$SESSION_LOG" 2>&1

exit 0
