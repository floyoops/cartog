# cartog-rag

Semantic search and RAG pipeline for cartog.

## Overview

Provides embedding-based code search on top of the cartog graph database. Combines keyword search (FTS5/BM25) with vector similarity (sqlite-vec) and cross-encoder reranking for high-quality results.

## How it works

### Models

- **Embedding**: BGE-small-en-v1.5 quantized — 384-dimensional vectors, ONNX runtime via fastembed (~80MB)
- **Reranker**: BGE-reranker-base — cross-encoder that scores (query, document) pairs jointly (~1.1GB, optional)

Both are auto-downloaded from HuggingFace on first use. Cached in `~/.cache/cartog/models/` (respects `FASTEMBED_CACHE_DIR` and `XDG_CACHE_HOME`).

### Hybrid search pipeline

1. **FTS5 keyword search** — BM25 ranking over symbol names and source content
2. **Vector KNN search** — cosine similarity on 384-dim embeddings via sqlite-vec
3. **RRF merge** — Reciprocal Rank Fusion (k=60) combines both ranked lists
4. **Hydration** — load symbol metadata and source content from the database
5. **Cross-encoder reranking** — reranker scores top-50 candidates (if model available)
6. **Final sort** — by rerank score (if present), else RRF score, with in-degree tiebreaker

Over-retrieves `(limit * 3).max(20)` candidates from each source to improve fusion quality before applying the final limit.

### Engine caching

- Embedding engine: `static Mutex`, loaded once per process, reused across calls
- Reranker engine: tri-state `Mutex` — `None` (not attempted), `Some(None)` (load failed, don't retry), `Some(Some(engine))` (ready)

## Public API

| Export | Description |
|--------|-------------|
| `search::hybrid_search()` | Run the full hybrid search pipeline |
| `indexer::index_embeddings()` | Embed symbols and write vectors to DB |
| `setup::download_model()` | Download the embedding model |
| `setup::download_cross_encoder()` | Download the reranker model |
| `embeddings::EmbeddingEngine` | Low-level embedding interface |
| `reranker::CrossEncoderEngine` | Low-level reranker interface |
| `EMBEDDING_DIM` | 384 (vector dimension constant) |
| `is_embedding_model_cached()` | Check if embedding model is downloaded |
| `is_reranker_model_cached()` | Check if reranker model is downloaded |

## Crate dependencies

`cartog-core`, `cartog-db`
