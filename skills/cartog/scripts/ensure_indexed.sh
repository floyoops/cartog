#!/usr/bin/env bash
set -euo pipefail

# Ensure the cartog index exists and is up to date.
# Run this at the start of a coding session.
#
# Foreground (must finish before Claude responds):
#   F1. Install cartog if the binary is missing (MCP server can't start without it).
#   F2. Code graph index (fast, incremental — usually <1s for unchanged codebases).
#
# Background (forked into one subshell, logged to ~/.cache/cartog/session.log):
#   B1. Version sync: `cartog self update` (>=0.14.0) or install.sh (<0.14.0).
#   B2. Model download (`cartog rag setup`) — enables cross-encoder reranker.
#   B3. RAG embedding (`cartog rag index`) — enables vector/semantic search.
#
# Failures during the background pipeline are written to the log file and
# surfaced on the next session via a marker file at ~/.cache/cartog/last-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR="."
LOCK_DIR="${CARTOG_LOCK_DIR:-/tmp/cartog-rag-index.lock}"

# Resolve the database path using the same priority as the Rust binary:
#   1. CARTOG_DB env var (explicit override)
#   2. .cartog.toml database.path (local project config)
#   3. Git root detection (walk up from cwd to find .git, place DB there)
#   4. cwd fallback (.cartog.db in the current directory)
if [ -n "${CARTOG_DB:-}" ]; then
    DB_FILE="$CARTOG_DB"
else
    # Check .cartog.toml for database.path
    TOML_DB=""
    GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    for _dir in "." "$GIT_ROOT"; do
        [ -n "$_dir" ] && [ -f "$_dir/.cartog.toml" ] && {
            TOML_DB="$(sed -n '/^\[database\]/,/^\[/{s/^path[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p;}' "$_dir/.cartog.toml" 2>/dev/null)" || true
            [ -n "$TOML_DB" ] && break
        }
    done
    if [ -n "$TOML_DB" ]; then
        # Expand leading ~/
        case "$TOML_DB" in
            "~/"*) DB_FILE="${HOME}${TOML_DB#\~}" ;;
            *)     DB_FILE="$TOML_DB" ;;
        esac
    elif [ -n "$GIT_ROOT" ]; then
        DB_FILE="${GIT_ROOT}/.cartog.db"
    else
        DB_FILE=".cartog.db"
    fi
fi

# Plugin tag is kept in sync with the binary version at release time.
# Reading it locally avoids any network call for the version check.
PLUGIN_JSON="${CARTOG_PLUGIN_JSON:-${SCRIPT_DIR}/../../../.claude-plugin/plugin.json}"
PLUGIN_VERSION="$( { sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" 2>/dev/null || true; } | head -n 1)"

# Background log directory. Falls back to /tmp if ~/.cache isn't writable.
SESSION_LOG_DIR="${CARTOG_LOG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/cartog}"
if ! mkdir -p "$SESSION_LOG_DIR" 2>/dev/null; then
    SESSION_LOG_DIR="/tmp"
fi
SESSION_LOG="$SESSION_LOG_DIR/session.log"
LAST_ERROR_FILE="$SESSION_LOG_DIR/last-error"

# Surface any error from the previous session's background pipeline.
if [ -f "$LAST_ERROR_FILE" ]; then
    echo "Previous cartog background task failed:" >&2
    cat "$LAST_ERROR_FILE" >&2
    rm -f "$LAST_ERROR_FILE"
fi

# Semver compare: returns 0 iff $1 > $2 component-wise.
# Pre-release suffixes (e.g. 0.14.0-rc.1) are stripped — bare numeric triple compare.
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

# F1: install cartog only when the binary is missing. Outdated-but-present
# binaries are upgraded asynchronously in the background pipeline, so this
# function does NOT touch the network when cartog is already on PATH.
ensure_cartog_installed() {
    if command -v cartog >/dev/null 2>&1; then
        return 0
    fi
    echo "cartog binary not found on PATH. Installing via $SCRIPT_DIR/install.sh..." >&2
    # Pin to the version this skill was tested against to avoid drift on the next session.
    if ! bash "$SCRIPT_DIR/install.sh" ${PLUGIN_VERSION:+"$PLUGIN_VERSION"} >&2; then
        echo "cartog install failed. See output above." >&2
        exit 1
    fi
    # install.sh may drop the binary in $HOME/.cargo/bin without it being on PATH yet.
    if ! command -v cartog >/dev/null 2>&1; then
        export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
    fi
    if ! command -v cartog >/dev/null 2>&1; then
        echo "cartog still not on PATH after install. Add ${CARGO_HOME:-\$HOME/.cargo}/bin to PATH and retry." >&2
        exit 1
    fi
}

# B1 (runs in background): bring an existing binary in sync with the plugin's
# pinned version. Mirrors the previous foreground branching:
#   installed == PLUGIN_VERSION → noop
#   installed >= 0.14.0         → `cartog self update`
#   installed <  0.14.0         → install.sh (pre-self-update bootstrap)
#   PLUGIN_VERSION missing      → `cartog self update --check` then maybe self update
# All output goes to the caller's stdout — the background subshell appends it to SESSION_LOG.
sync_cartog_version_bg() {
    local installed
    installed="$(cartog --version 2>/dev/null | head -n 1 | sed -E 's/^cartog ([^ ]+).*/\1/')"
    [ -n "$installed" ] || return 0

    if [ -n "$PLUGIN_VERSION" ] && [ "$installed" = "$PLUGIN_VERSION" ]; then
        return 0
    fi

    local install_label="${PLUGIN_VERSION:-latest}"
    local self_update_label="latest"

    if version_gt "0.14.0" "$installed"; then
        echo "Updating cartog $installed → $install_label via $SCRIPT_DIR/install.sh (pre-self-update)..."
        if ! bash "$SCRIPT_DIR/install.sh" ${PLUGIN_VERSION:+"$PLUGIN_VERSION"}; then
            echo "cartog install failed. See output above."
            return 1
        fi
        return 0
    fi

    if [ -z "$PLUGIN_VERSION" ]; then
        local rc=0
        cartog self update --check --quiet 2>/dev/null || rc=$?
        # rc: 0 = up to date, 1 = update available, 2 = network error.
        [ "$rc" -eq 1 ] || return 0
    fi

    echo "Updating cartog $installed → $self_update_label via 'cartog self update'..."
    local update_output update_rc
    update_output="$(cartog self update 2>&1)" && update_rc=0 || update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
        echo "cartog self update failed (exit $update_rc):"
        printf '%s\n' "$update_output"
        return 1
    fi
    printf '%s\n' "$update_output"
}

# Background pipeline: version sync → model download → RAG embedding.
# Single subshell guarded by LOCK_DIR; failures recorded to LAST_ERROR_FILE
# so the next session surfaces them.
run_background_pipeline() {
    local pipeline_rc=0
    {
        echo "=== cartog session log $(date '+%Y-%m-%d %H:%M:%S') ==="
        echo "--- B1: version sync ---"
        if ! sync_cartog_version_bg; then
            pipeline_rc=1
            echo "B1 failed; skipping B2 and B3." >&2
        else
            echo "--- B2: rag setup (model download) ---"
            if ! cartog rag setup; then
                pipeline_rc=1
                echo "B2 failed; semantic search will use FTS5 only (no reranker)." >&2
            fi
            echo "--- B3: rag index (vector embedding) ---"
            if ! cartog rag index .; then
                pipeline_rc=1
                echo "B3 failed; vector search unavailable." >&2
            fi
        fi
        echo "=== pipeline exit $pipeline_rc ==="
    } >> "$SESSION_LOG" 2>&1

    if [ "$pipeline_rc" -ne 0 ]; then
        printf 'See %s for details (pipeline exit %d).\n' "$SESSION_LOG" "$pipeline_rc" > "$LAST_ERROR_FILE"
    fi
    return "$pipeline_rc"
}

# --- Foreground execution starts here ---

ensure_cartog_installed

# F2: Code graph index — kept foreground because cartog MCP queries depend on it
# and it's typically <1s for incremental updates.
if [ ! -f "$DB_FILE" ]; then
    echo "No cartog index found. Building..."
else
    echo "Updating cartog index..."
fi
cartog index .

# Background pipeline: version sync + model download + RAG embedding.
# Stale lock (>1h) is removed automatically — handles crashed processes where trap didn't fire.
if [ -d "$LOCK_DIR" ]; then
    # GNU stat (Linux) uses -c %Y; BSD stat (macOS) uses -f %m. Try GNU first
    # because BSD `stat -f %m` would *succeed* on Linux (printing filesystem
    # stats instead of mtime), which would corrupt the arithmetic below.
    lock_mtime="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)"
    case "$lock_mtime" in
        ''|*[!0-9]*) lock_mtime=0 ;;
    esac
    lock_age=$(( $(date +%s) - lock_mtime ))
    if [ "$lock_age" -gt 3600 ]; then
        echo "Removing stale cartog background lock (${lock_age}s old)."
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
fi
if mkdir "$LOCK_DIR" 2>/dev/null; then
    (
        trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
        run_background_pipeline
    ) &
    BG_PID=$!
    disown "$BG_PID" 2>/dev/null || true
    echo "cartog background tasks started (PID $BG_PID, log: $SESSION_LOG)"
    echo "cartog index ready. Reranker + vector search become available once background tasks complete."
else
    echo "cartog background pipeline already running (lock: $LOCK_DIR), skipping."
    echo "cartog index ready."
fi
