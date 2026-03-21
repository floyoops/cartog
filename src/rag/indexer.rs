use anyhow::{Context, Result};
use tracing::info;

use crate::db::Database;

use super::embeddings::{embedding_to_bytes, EmbeddingEngine};

/// Result of a RAG indexing operation.
#[derive(Debug, Default, serde::Serialize)]
pub struct RagIndexResult {
    pub symbols_embedded: u32,
    pub symbols_skipped: u32,
    pub total_content_symbols: u32,
}

/// Maximum number of texts sent to the embedding engine in one call.
/// fastembed sub-batches internally, but chunking here controls progress reporting.
const CHUNK_SIZE: usize = 512;

/// Maximum pending DB writes before flushing to SQLite.
const DB_BATCH_LIMIT: usize = 256;

/// Process a batch of texts through the embedding engine and write results to DB.
///
/// Returns the number of successfully processed items in this batch.
fn flush_embedding_batch(
    engine: &mut EmbeddingEngine,
    db: &Database,
    texts: &[String],
    symbol_ids: &[String],
    db_batch: &mut Vec<(i64, Vec<u8>)>,
    result: &mut RagIndexResult,
) -> Result<usize> {
    let str_refs: Vec<&str> = texts.iter().map(|s| s.as_str()).collect();
    match engine.embed_batch(&str_refs) {
        Ok(embeddings) => {
            for (embedding, sid) in embeddings.iter().zip(symbol_ids.iter()) {
                let embedding_id = db.get_or_create_embedding_id(sid)?;
                let bytes = embedding_to_bytes(embedding);
                db_batch.push((embedding_id, bytes));
                result.symbols_embedded += 1;

                if db_batch.len() >= DB_BATCH_LIMIT {
                    db.insert_embeddings(db_batch)?;
                    db_batch.clear();
                }
            }
            Ok(embeddings.len())
        }
        Err(e) => {
            // Batch failed — fall back to one-at-a-time to isolate the bad symbol
            tracing::warn!(error = %e, "Batch embedding failed, falling back to sequential");
            let mut count = 0;
            for (text, sid) in texts.iter().zip(symbol_ids.iter()) {
                match engine.embed(text) {
                    Ok(embedding) => {
                        let embedding_id = db.get_or_create_embedding_id(sid)?;
                        let bytes = embedding_to_bytes(&embedding);
                        db_batch.push((embedding_id, bytes));
                        result.symbols_embedded += 1;
                        count += 1;

                        if db_batch.len() >= DB_BATCH_LIMIT {
                            db.insert_embeddings(db_batch)?;
                            db_batch.clear();
                        }
                    }
                    Err(e2) => {
                        tracing::warn!(symbol = %sid, error = %e2, "embedding failed, skipping");
                        result.symbols_skipped += 1;
                    }
                }
            }
            Ok(count)
        }
    }
}

/// Embedding format version. Increment when changing `compact_embedding_text` logic.
///
/// Stored in metadata as `embedding_format_version`. When the stored version differs
/// from this constant, `index_embeddings` automatically forces a full re-embed.
pub const EMBEDDING_FORMAT_VERSION: u32 = 2;

/// Maximum bytes for the embedding text sent to the model.
///
/// BGE-small-en-v1.5 has a 512-token limit. At ~3-4 chars/token for code,
/// 800 bytes ≈ 200-270 tokens — well within budget while leaving room for the
/// query in the model's attention window.
const MAX_EMBED_TEXT_BYTES: usize = 800;

/// Build embedding text for a symbol: header + signature + significant body lines.
///
/// Skips blank lines, comment-only lines, and brace-only lines to maximize
/// semantic signal per token. Keeps decorators/annotations (they carry meaning
/// like `@login_required`, `#[derive(Serialize)]`).
///
/// Full content stays in `symbol_content` for FTS5 keyword search and
/// cross-encoder re-ranking — this function only controls what gets embedded
/// for vector similarity.
pub fn compact_embedding_text(header: &str, content: &str) -> String {
    let mut out = String::with_capacity(MAX_EMBED_TEXT_BYTES);
    out.push_str(header);

    for line in content.lines() {
        if out.len() >= MAX_EMBED_TEXT_BYTES {
            break;
        }
        if is_insignificant_line(line) {
            continue;
        }
        out.push('\n');
        let remaining = MAX_EMBED_TEXT_BYTES.saturating_sub(out.len());
        if line.len() > remaining {
            out.push_str(&line[..remaining]);
            break;
        }
        out.push_str(line);
    }

    out
}

/// Returns true for lines that add little semantic value for embedding:
/// blank lines, comment-only lines, and closing-brace-only lines.
fn is_insignificant_line(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return true;
    }
    // Closing braces/brackets only: }, }, end, })
    if matches!(trimmed, "}" | "})" | "};" | "end" | ")" | "]" | "])") {
        return true;
    }
    // Comment-only lines across common languages
    if trimmed.starts_with("//")
        || trimmed.starts_with('#')
        || trimmed.starts_with("--")
        || trimmed.starts_with('*')
        || trimmed.starts_with("/*")
        || trimmed.starts_with("'''")
        || trimmed.starts_with("\"\"\"")
    {
        return true;
    }
    false
}

/// Embed all symbols that have content but no embedding yet.
///
/// Requires the embedding model to be available (downloaded via `cartog rag setup`
/// or auto-downloaded on first use by fastembed).
/// When `force` is true, clears all existing embeddings and re-embeds everything.
pub fn index_embeddings(db: &Database, force: bool) -> Result<RagIndexResult> {
    let mut engine = EmbeddingEngine::new()
        .context("Failed to load embedding model. Run 'cartog rag setup' to download it.")?;

    let total_content_symbols = db.symbol_content_count()?;

    // Auto-detect embedding format change and force re-embed
    let stored_version: u32 = db
        .get_metadata("embedding_format_version")?
        .and_then(|v| v.parse().ok())
        .unwrap_or(1);
    let format_changed = stored_version < EMBEDDING_FORMAT_VERSION;
    let force = force || format_changed;

    if format_changed {
        info!(
            "Embedding format upgraded (v{stored_version} → v{EMBEDDING_FORMAT_VERSION}), re-embedding all symbols"
        );
    }

    if force {
        info!("Force mode: clearing all existing embeddings");
        db.clear_all_embeddings()?;
    }

    let symbol_ids = if force {
        db.all_content_symbol_ids()?
    } else {
        db.symbols_needing_embeddings()?
    };

    let mut result = RagIndexResult {
        total_content_symbols,
        ..Default::default()
    };

    if symbol_ids.is_empty() {
        info!("No symbols need embedding");
        return Ok(result);
    }

    info!("Embedding {} symbols...", symbol_ids.len());

    let mut db_batch: Vec<(i64, Vec<u8>)> = Vec::with_capacity(DB_BATCH_LIMIT);
    let mut texts: Vec<String> = Vec::with_capacity(CHUNK_SIZE);
    let mut text_symbol_ids: Vec<String> = Vec::with_capacity(CHUNK_SIZE);

    let total = symbol_ids.len();
    let mut processed = 0usize;

    // Process in chunks, batch-fetching content for each chunk
    for chunk in symbol_ids.chunks(CHUNK_SIZE) {
        let chunk_vec: Vec<String> = chunk.to_vec();
        let content_map = db.get_symbol_contents_batch(&chunk_vec)?;

        for symbol_id in chunk {
            let (content, header) = match content_map.get(symbol_id) {
                Some(c) => c,
                None => {
                    result.symbols_skipped += 1;
                    continue;
                }
            };

            texts.push(compact_embedding_text(header, content));
            text_symbol_ids.push(symbol_id.clone());

            if texts.len() >= CHUNK_SIZE {
                let count = flush_embedding_batch(
                    &mut engine,
                    db,
                    &texts,
                    &text_symbol_ids,
                    &mut db_batch,
                    &mut result,
                )?;
                processed += count;
                texts.clear();
                text_symbol_ids.clear();

                if processed % 1000 < CHUNK_SIZE {
                    info!("  {processed}/{total} symbols embedded");
                }
            }
        }
    }

    // Flush remaining texts
    if !texts.is_empty() {
        let count = flush_embedding_batch(
            &mut engine,
            db,
            &texts,
            &text_symbol_ids,
            &mut db_batch,
            &mut result,
        )?;
        processed += count;
    }

    // Flush remaining DB writes
    if !db_batch.is_empty() {
        db.insert_embeddings(&db_batch)?;
    }

    // Store the current embedding format version
    db.set_metadata(
        "embedding_format_version",
        &EMBEDDING_FORMAT_VERSION.to_string(),
    )?;

    info!(
        "Done: {} embedded, {} skipped ({processed}/{total} processed)",
        result.symbols_embedded, result.symbols_skipped
    );

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compact_embedding_text_includes_significant_lines() {
        let header = "// File: auth.py | function validate_token";
        let content = "def validate_token(token: str) -> bool:\n    if token.is_expired():\n        raise TokenError('expired')\n    return True";
        let result = compact_embedding_text(header, content);
        assert!(result.contains("validate_token(token: str)"));
        assert!(result.contains("token.is_expired()"));
        assert!(result.contains("raise TokenError"));
        assert!(result.contains("return True"));
    }

    #[test]
    fn test_compact_embedding_text_skips_blanks_and_comments() {
        let header = "header";
        let content = "def foo():\n    # setup\n\n    x = 1\n    // another comment\n    y = 2\n\n    return x + y";
        let result = compact_embedding_text(header, content);
        assert!(result.contains("def foo():"));
        assert!(result.contains("x = 1"));
        assert!(result.contains("y = 2"));
        assert!(result.contains("return x + y"));
        assert!(!result.contains("# setup"));
        assert!(!result.contains("// another comment"));
    }

    #[test]
    fn test_compact_embedding_text_skips_closing_braces() {
        let header = "header";
        let content = "fn main() {\n    let x = 1;\n    println!(x);\n}";
        let result = compact_embedding_text(header, content);
        assert!(result.contains("fn main()"));
        assert!(result.contains("let x = 1;"));
        assert!(result.contains("println!(x);"));
        assert!(!result.ends_with("\n}"));
    }

    #[test]
    fn test_compact_embedding_text_keeps_decorators() {
        let header = "header";
        let content = "@login_required\n@cached(ttl=300)\ndef protected_view(request):\n    return render(request)";
        let result = compact_embedding_text(header, content);
        assert!(result.contains("@login_required"));
        assert!(result.contains("@cached(ttl=300)"));
        assert!(result.contains("def protected_view"));
    }

    #[test]
    fn test_compact_embedding_text_single_line() {
        let header = "// File: config.py | variable MAX_RETRIES";
        let content = "MAX_RETRIES = 3";
        let result = compact_embedding_text(header, content);
        assert!(result.contains("MAX_RETRIES = 3"));
    }

    #[test]
    fn test_compact_embedding_text_empty_content() {
        let header = "// File: a.py | function foo";
        let content = "";
        let result = compact_embedding_text(header, content);
        assert_eq!(result, "// File: a.py | function foo");
    }

    #[test]
    fn test_compact_embedding_text_respects_byte_limit() {
        let header = "header";
        // Build content with many significant lines that exceed MAX_EMBED_TEXT_BYTES
        let lines: Vec<String> = (0..100)
            .map(|i| format!("    let var_{i} = compute({i});"))
            .collect();
        let content = lines.join("\n");
        let result = compact_embedding_text(header, &content);
        assert!(result.len() <= MAX_EMBED_TEXT_BYTES + 50); // small tolerance for last line
    }

    #[test]
    fn test_is_insignificant_line() {
        assert!(is_insignificant_line(""));
        assert!(is_insignificant_line("   "));
        assert!(is_insignificant_line("// comment"));
        assert!(is_insignificant_line("# comment"));
        assert!(is_insignificant_line("  # comment"));
        assert!(is_insignificant_line("  }"));
        assert!(is_insignificant_line("})"));
        assert!(is_insignificant_line("end"));
        assert!(is_insignificant_line("  * javadoc line"));
        assert!(is_insignificant_line("  \"\"\"docstring\"\"\""));

        assert!(!is_insignificant_line("let x = 1;"));
        assert!(!is_insignificant_line("@login_required"));
        assert!(!is_insignificant_line("def foo():"));
        assert!(!is_insignificant_line("  return x + y"));
        assert!(!is_insignificant_line("  hash_map.insert(key, value);"));
    }
}
