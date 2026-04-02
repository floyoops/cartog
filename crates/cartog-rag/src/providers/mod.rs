pub const DEFAULT_OLLAMA_BASE_URL: &str = "http://localhost:11434";
pub const DEFAULT_OLLAMA_MODEL: &str = "nomic-embed-text";

#[cfg(feature = "provider-local")]
pub mod local;
#[cfg(feature = "provider-ollama")]
pub mod ollama;
