//! Semantic search and RAG pipeline for cartog.
//!
//! Combines FTS5 keyword search (BM25) with vector KNN search (BGE-small-en-v1.5,
//! 384-dim embeddings via fastembed) using Reciprocal Rank Fusion, then optionally
//! reranks with a cross-encoder (BGE-reranker-base).

pub mod embeddings;
pub mod indexer;
pub mod reranker;
pub mod search;
pub mod setup;

/// Embedding dimension for the bge-small-en-v1.5 model.
pub const EMBEDDING_DIM: usize = 384;

/// HuggingFace repo ID for the quantized embedding model.
const EMBEDDING_MODEL_CODE: &str = "Qdrant/bge-small-en-v1.5-onnx-Q";
/// Primary ONNX file that must exist for the embedding model to be considered cached.
const EMBEDDING_MODEL_FILE: &str = "model_optimized.onnx";
/// HuggingFace repo ID for the cross-encoder reranker model.
const RERANKER_MODEL_CODE: &str = "BAAI/bge-reranker-base";
/// Primary ONNX file that must exist for the reranker model to be considered cached.
const RERANKER_MODEL_FILE: &str = "onnx/model.onnx";

/// Check if a model is already downloaded in the hf-hub cache (no network access).
///
/// Mirrors `hf_hub::CacheRepo::get()` logic: reads the commit hash from
/// `<cache>/models--<org>--<name>/refs/main`, then checks for the ONNX file
/// in `snapshots/<hash>/<model_file>`.
fn is_model_cached(model_code: &str, model_file: &str) -> bool {
    let cache_dir = model_cache_dir();
    let dir_name = format!("models--{}", model_code.replace('/', "--"));
    let ref_path = cache_dir.join(&dir_name).join("refs").join("main");
    let Ok(commit_hash) = std::fs::read_to_string(&ref_path) else {
        return false;
    };
    let model_path = cache_dir
        .join(&dir_name)
        .join("snapshots")
        .join(commit_hash.trim())
        .join(model_file);
    model_path.exists()
}

/// Whether the embedding model (BGE-small-en-v1.5 quantized) is already cached.
pub fn is_embedding_model_cached() -> bool {
    is_model_cached(EMBEDDING_MODEL_CODE, EMBEDDING_MODEL_FILE)
}

/// Whether the cross-encoder reranker model (BGE-reranker-base) is already cached.
pub fn is_reranker_model_cached() -> bool {
    is_model_cached(RERANKER_MODEL_CODE, RERANKER_MODEL_FILE)
}

/// Shared model cache directory for ONNX models (embedding + reranker).
///
/// Precedence:
/// 1. `FASTEMBED_CACHE_DIR` env var (fastembed's own convention)
/// 2. `XDG_CACHE_HOME/cartog/models` (XDG standard)
/// 3. `~/.cache/cartog/models` (fallback)
///
/// This avoids downloading 1.2GB of models per project (fastembed's default is
/// `.fastembed_cache` in CWD).
pub fn model_cache_dir() -> std::path::PathBuf {
    // 1. Respect fastembed's own env var
    if let Ok(dir) = std::env::var("FASTEMBED_CACHE_DIR") {
        return std::path::PathBuf::from(dir);
    }

    // 2. XDG_CACHE_HOME / cartog / models
    if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
        return std::path::PathBuf::from(xdg).join("cartog").join("models");
    }

    // 3. ~/.cache/cartog/models
    if let Some(home) = home_dir() {
        return home.join(".cache").join("cartog").join("models");
    }

    // Last resort: fastembed's default (CWD/.fastembed_cache)
    std::path::PathBuf::from(".fastembed_cache")
}

/// Get the user's home directory (no external dependency needed).
fn home_dir() -> Option<std::path::PathBuf> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE")) // Windows fallback
        .ok()
        .map(std::path::PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_model_cache_dir_is_not_local() {
        // Unless FASTEMBED_CACHE_DIR is explicitly set to a local path,
        // model_cache_dir should NOT return ".fastembed_cache" (the per-project default).
        let dir = model_cache_dir();
        let dir_str = dir.to_string_lossy();
        // On any system with HOME set, this should be an absolute path
        if std::env::var("FASTEMBED_CACHE_DIR").is_err() {
            assert!(
                dir_str.contains("cartog"),
                "cache dir should contain 'cartog', got: {dir_str}"
            );
            assert!(
                !dir_str.starts_with('.'),
                "cache dir should be absolute, not relative: {dir_str}"
            );
        }
    }

    #[test]
    fn test_model_cache_dir_ends_with_models() {
        if std::env::var("FASTEMBED_CACHE_DIR").is_err() {
            let dir = model_cache_dir();
            assert!(
                dir.ends_with("models"),
                "cache dir should end with 'models', got: {}",
                dir.display()
            );
        }
    }
}
