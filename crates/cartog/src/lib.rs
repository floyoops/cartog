//! Cartog — code graph indexer for LLM coding agents.
//!
//! This library facade re-exports all workspace crates under the `cartog::`
//! namespace (e.g., `cartog::db`, `cartog::types`, `cartog::indexer`).

pub use cartog_core as types;
pub use cartog_db as db;
pub use cartog_indexer as indexer;
pub use cartog_languages as languages;
pub use cartog_rag as rag;
pub use cartog_watch as watch;

#[cfg(feature = "lsp")]
pub use cartog_lsp as lsp;
