# cartog-rag

Semantic search and RAG pipeline for cartog.

## Overview

Provides embedding-based search on top of the cartog graph database. Combines keyword search (FTS5/BM25) with vector similarity (sqlite-vec) and cross-encoder reranking for high-quality results.

Indexes both **code symbols** (functions, classes, methods) and **Markdown documents** (chunked by heading). Documentation and code are searchable side-by-side with the same hybrid pipeline.

## How it works

### Embedding providers

Configurable via `.cartog.toml` `[embedding]` section. Supports pluggable providers:

| Provider | Feature flag | Models | Notes |
|----------|-------------|--------|-------|
| **local** (default) | `provider-local` | Any fastembed built-in (BGE, all-MiniLM, nomic, etc.) | ONNX Runtime via fastembed, auto-downloaded from HuggingFace |
| **ollama** | `provider-ollama` | Any Ollama model (nomic-embed-text, mxbai-embed-large, etc.) | HTTP client, auto-detects dimension |

**Reranker**: BGE-reranker-base — cross-encoder that scores (query, document) pairs jointly (~1.1GB, optional, local only).

Models cached in `~/.cache/cartog/models/` (respects `FASTEMBED_CACHE_DIR` and `XDG_CACHE_HOME`).

```toml
# .cartog.toml — example with Ollama
[embedding]
provider = "ollama"
model = "nomic-embed-text"
# dimension = 768  # auto-detected if omitted

[embedding.local]
# query_prefix = "search_query: "
# document_prefix = "search_document: "
```

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
