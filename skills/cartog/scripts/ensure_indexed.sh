#!/usr/bin/env bash
set -euo pipefail

# Ensure the cartog index exists and is up to date.
# Run this at the start of a coding session.
#
# Three phases:
#   1. Code graph index (blocking, fast — incremental, < 1s for unchanged codebases)
#   2. Model download (blocking, one-time — enables cross-encoder reranker on FTS5 results)
#   3. RAG embedding (background — vector search becomes available when done)
#
# After phase 2, `cartog rag search` already works (FTS5 + reranker).
# Phase 3 adds vector/semantic matching in the background without blocking the agent.

DB_FILE=".cartog.db"
LOCK_DIR="/tmp/cartog-rag-index.lock"

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
