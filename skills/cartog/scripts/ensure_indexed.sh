#!/usr/bin/env bash
set -euo pipefail

# Ensure the cartog index exists and is up to date.
# Run this at the start of a coding session.
#
# Four phases:
#   0. Ensure cartog matches plugin.json version: missing → install.sh;
#      outdated and >=0.14.0 → `cartog self update`; outdated and <0.14.0 → install.sh.
#      Any failure exits 1 with the underlying error surfaced.
#   1. Code graph index (blocking, fast — incremental, < 1s for unchanged codebases)
#   2. Model download (blocking, one-time — enables cross-encoder reranker on FTS5 results)
#   3. RAG embedding (background — vector search becomes available when done)
#
# After phase 2, `cartog rag search` already works (FTS5 + reranker).
# Phase 3 adds vector/semantic matching in the background without blocking the agent.

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

# Phase 0: ensure cartog is installed and (when known) synced to the plugin's pinned version.
# Target version:
#   PLUGIN_VERSION present → sync exactly to it (this is what release tags ship).
#   PLUGIN_VERSION missing → "latest" (best-effort self update; legacy binaries reinstall).
# Branches:
#   Missing binary               → install.sh
#   installed != target:
#     installed >= 0.14.0        → `cartog self update` (CLI added in 0.14.0)
#     installed <  0.14.0        → install.sh (no self update CLI, bootstrap fallback)
# Either failure exits 1 with the underlying error surfaced.
ensure_cartog() {
    if ! command -v cartog >/dev/null 2>&1; then
        echo "cartog binary not found on PATH. Installing via $SCRIPT_DIR/install.sh..." >&2
        # Pass PLUGIN_VERSION so a fresh install pins to the version this skill
        # was tested against — avoids version drift on the very next session.
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
    fi

    local installed
    installed="$(cartog --version 2>/dev/null | head -n 1 | sed -E 's/^cartog ([^ ]+).*/\1/')"
    [ -n "$installed" ] || return 0

    # If we know the plugin's pinned version, treat in-sync as a no-op.
    # Without it, fall through to "self update to latest" (legacy → install.sh).
    if [ -n "$PLUGIN_VERSION" ] && [ "$installed" = "$PLUGIN_VERSION" ]; then
        return 0
    fi

    # `cartog self update` always installs the latest release; install.sh accepts
    # a pinned version. Label the announce so the destination is honest.
    local install_label="${PLUGIN_VERSION:-latest}"
    local self_update_label="latest"

    if version_gt "0.14.0" "$installed"; then
        # No `cartog self update` CLI before 0.14.0 — bootstrap via install.sh.
        echo "Updating cartog $installed → $install_label via $SCRIPT_DIR/install.sh (pre-self-update)..."
        if ! bash "$SCRIPT_DIR/install.sh" ${PLUGIN_VERSION:+"$PLUGIN_VERSION"} >&2; then
            echo "cartog install failed. See output above." >&2
            exit 1
        fi
        return 0
    fi

    # No plugin version pinned and the binary may already be at latest.
    # Use `--check` to avoid a no-op self update.
    if [ -z "$PLUGIN_VERSION" ]; then
        local rc=0
        cartog self update --check --quiet 2>/dev/null || rc=$?
        # rc: 0 = up to date, 1 = update available, 2 = network error.
        # Only proceed when rc=1; everything else is "do nothing".
        [ "$rc" -eq 1 ] || return 0
    fi

    echo "Updating cartog $installed → $self_update_label via 'cartog self update'..."
    local update_output update_rc
    update_output="$(cartog self update 2>&1)" && update_rc=0 || update_rc=$?
    if [ "$update_rc" -ne 0 ]; then
        echo "cartog self update failed (exit $update_rc):" >&2
        printf '%s\n' "$update_output" >&2
        exit 1
    fi
    printf '%s\n' "$update_output"
}

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

ensure_cartog

# Phase 1: Code graph index (always fast, incremental)
if [ ! -f "$DB_FILE" ]; then
    echo "No cartog index found. Building..."
else
    echo "Updating cartog index..."
fi
cartog index .

# Phase 2: Download embedding + reranker models (one-time, cached in ~/.cache/cartog/models/)
# This enables the cross-encoder reranker even before vector embeddings exist.
# stderr is NOT redirected so progress/download messages are visible in AI editors.
if ! cartog rag setup; then
    echo "Warning: cartog rag setup failed. Semantic search will use FTS5-only (no reranker)."
fi

# Phase 3: RAG embedding in background (non-blocking)
# Uses a lock directory to prevent concurrent rag index processes across sessions.
# Stale lock (>1 hour) is removed automatically — handles crashed processes where trap didn't fire.
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
        echo "Removing stale RAG lock (${lock_age}s old)."
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
fi
if mkdir "$LOCK_DIR" 2>/dev/null; then
    RAG_LOG="/tmp/cartog-rag-index-$$.log"
    (
        trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
        cartog rag index . > "$RAG_LOG" 2>&1
    ) &
    RAG_PID=$!
    disown "$RAG_PID" 2>/dev/null || true
    echo "RAG embedding started in background (PID $RAG_PID, log: $RAG_LOG)"
    echo "cartog rag search works now (FTS5 + reranker). Vector search available when embedding completes."
else
    echo "RAG embedding already running (lock: $LOCK_DIR), skipping."
    echo "cartog rag search works now (FTS5 + reranker)."
fi
