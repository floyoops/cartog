#!/usr/bin/env bash
set -euo pipefail

# Ensure the cartog index exists and is up to date.
# Run this at the start of a coding session.
#
# Four phases:
#   0. Version check (cached, non-blocking — notifies if a newer release exists)
#   1. Code graph index (blocking, fast — incremental, < 1s for unchanged codebases)
#   2. Model download (blocking, one-time — enables cross-encoder reranker on FTS5 results)
#   3. RAG embedding (background — vector search becomes available when done)
#
# After phase 2, `cartog rag search` already works (FTS5 + reranker).
# Phase 3 adds vector/semantic matching in the background without blocking the agent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
VERSION_CACHE="${HOME}/.cache/cartog/latest_version"
VERSION_TTL=86400  # 24 hours

# Phase 0: Check for newer cartog version (non-blocking, never installs).
# Delegates to `cartog self update --check` per BR-9 — the hook only ever
# *reports*; bootstrap and upgrades are user-initiated via install.sh /
# `cartog self update`. A local 24h cache short-circuits the network call
# on subsequent invocations within the same day.
check_update() {
    if ! command -v cartog >/dev/null 2>&1; then
        echo "cartog not found on PATH. Install with: bash $SCRIPT_DIR/install.sh"
        return 0
    fi

    local installed
    installed="$(cartog --version 2>/dev/null | head -n 1 | sed -E 's/^cartog ([^ ]+).*/\1/')"
    [ -n "$installed" ] || return 0

    local now latest=""
    now=$(date +%s)

    # Fresh cache (≤24h) — reuse the cached `latest` without hitting the
    # network. Still compare against `installed` so the outdated hint
    # surfaces on every session within the TTL window.
    if [ -f "$VERSION_CACHE" ]; then
        local cached_version cached_ts
        cached_version="$(cut -d' ' -f1 "$VERSION_CACHE" 2>/dev/null)" || true
        cached_ts="$(cut -d' ' -f2 "$VERSION_CACHE" 2>/dev/null)" || true
        if [ -n "$cached_ts" ] && [ $(( now - cached_ts )) -le "$VERSION_TTL" ]; then
            latest="$cached_version"
        fi
    fi

    if [ -z "$latest" ]; then
        # --check is read-only; --json gives a stable schema with `latest`.
        # Exit codes: 0 up to date, 1 outdated, 2 network/parse error.
        local output rc
        output="$(cartog self update --check --json 2>/dev/null)" && rc=0 || rc=$?
        case "$rc" in
            0|1) ;;
            *)   return 0 ;;
        esac
        latest="$(printf '%s' "$output" | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$latest" ] || return 0
        mkdir -p "$(dirname "$VERSION_CACHE")"
        echo "$latest $now" > "$VERSION_CACHE"
    fi

    if [ "$latest" != "$installed" ]; then
        echo "New cartog version available: $latest (installed: $installed). Run: cartog self update"
    fi
}

check_update || true

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
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
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
