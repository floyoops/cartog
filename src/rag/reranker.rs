use anyhow::{Context, Result};
use fastembed::{RerankInitOptions, RerankerModel, TextRerank};
use tracing::info;

use super::model_cache_dir;

/// Cross-encoder re-ranker for scoring (query, document) pairs.
///
/// Uses ONNX Runtime via fastembed for inference. The BGE-reranker-base model
/// processes query and document jointly through all transformer layers,
/// producing a relevance score for each pair.
pub struct CrossEncoderEngine {
    model: TextRerank,
}

impl CrossEncoderEngine {
    /// Load the cross-encoder re-ranker model.
    ///
    /// Downloads the model from HuggingFace on first use (~1.1GB).
    /// Progress is always enabled (visible in TTY via indicatif, logged via tracing
    /// for non-TTY environments like AI editors).
    /// Models are cached in the shared directory (see [`super::model_cache_dir`]).
    pub fn load() -> Result<Self> {
        if super::is_reranker_model_cached() {
            info!("Loading reranker model...");
        } else {
            info!("Downloading reranker model (~1.1GB, first time only)...");
        }

        let model = TextRerank::try_new(
            RerankInitOptions::new(RerankerModel::BGERerankerBase)
                .with_cache_dir(model_cache_dir())
                .with_show_download_progress(true),
        )
        .context("Failed to initialize cross-encoder model")?;

        Ok(Self { model })
    }

    /// Score multiple documents against a single query.
    ///
    /// Returns scores in the same order as the input documents.
    /// Uses index-based placement (O(n)) instead of sorting (O(n log n)).
    pub fn score_batch(&mut self, query: &str, documents: &[&str]) -> Result<Vec<f32>> {
        if documents.is_empty() {
            return Ok(Vec::new());
        }

        let results = self
            .model
            .rerank(query, documents, false, None)
            .context("Cross-encoder batch scoring failed")?;

        // Results come back sorted by score descending — place back by original index.
        let mut scores = vec![0.0f32; documents.len()];
        for r in &results {
            scores[r.index] = r.score;
        }

        Ok(scores)
    }
}
