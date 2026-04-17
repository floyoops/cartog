# Contributing to cartog

## Before you start

- Search [existing issues](https://github.com/jrollin/cartog/issues) and PRs to avoid duplicate work.
- For significant changes, open an issue first to align on the approach before writing code.

## Setup

Requires Rust MSRV 1.77.

```bash
cargo build                         # default build (includes LSP)
cargo build --no-default-features   # minimal build without LSP
```

## Quality checks

All checks must pass before submitting a PR:

```bash
make check        # cargo fmt + clippy + test + fixture validation + skill tests
```

Individual targets:

```bash
make check-rust       # cargo fmt --check + clippy -D warnings + cargo test
make check-fixtures   # validate all language fixture codebases (py, go, rs, rb, java)
make check-skill      # bash unit tests for the agent skill
```

## Commit style

This project uses [conventional commits](https://www.conventionalcommits.org/). git-cliff generates the changelog from commit messages automatically — no manual CHANGELOG edits needed.

Format: `type(scope): description`

| Type | When to use |
|------|-------------|
| `feat` | New user-visible feature |
| `fix` | Bug fix |
| `perf` | Performance improvement |
| `refactor` | Internal restructuring |
| `test` | Tests only |
| `docs` | Documentation only |
| `chore` | Tooling, deps, release |

Common scopes: `lang`, `db`, `mcp`, `search`, `index`, `watch`, `skill`, `ci`

Examples:
```
feat(lang): add C++ support
fix(db): resolve connection leak on reindex
perf(search): reduce query latency with covering index
docs(usage): add MCP Zed configuration example
```

## Adding a new language extractor

1. Create `src/languages/<lang>.rs` implementing the `Extractor` trait:
   ```rust
   pub struct MyLangExtractor { parser: tree_sitter::Parser }
   impl Extractor for MyLangExtractor {
       fn extract(&mut self, source: &str, file_path: &str) -> Result<ExtractionResult> { ... }
   }
   ```
2. Register the module and file extension in `src/languages/mod.rs`:
   - Add `pub mod <lang>;` at the top
   - Add the extension mapping in `detect_language()`
3. Add a test fixture under `benchmarks/fixtures/webapp_<lang>/`
4. Run `make check-fixtures` to validate the fixture compiles/parses

## Feature flags

| Flag | Description |
|------|-------------|
| `lsp` | Opt-in LSP-based edge resolution (requires `url` crate) |

## Single maintainer

This is a solo-maintained project. PRs and issues are reviewed on a best-effort basis.

## References

- Architecture and tech decisions: [docs/tech.md](docs/tech.md)
- Product context and goals: [docs/product.md](docs/product.md)
- CLI, MCP, and skill setup: [docs/usage.md](docs/usage.md)
