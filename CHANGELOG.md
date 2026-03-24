# Changelog

## [0.7.2] - 2026-03-24

### Bug Fixes

- Remove redundant clippy-flagged test assertion and enforce fmt/clippy in AGENTS.md ([`203825b`](https://github.com/jrollin/cartog/commit/203825bd6e1fe4ec3816231d92477c3eab56e5d9))
- Format error ([`515cd67`](https://github.com/jrollin/cartog/commit/515cd67f687b90c150d5c7ce451d7310f3ac4111))
- **extract**: Capture calls in package-level var/const initializers ([`3735bd6`](https://github.com/jrollin/cartog/commit/3735bd6e38cfd439ff8cfc0d114f98a672679043))
- **search**: Rank definitions above variables/imports in search results ([`bdfa966`](https://github.com/jrollin/cartog/commit/bdfa966ac8e7fe51d5fd029ec69860bed280622e))
- **ci**: Resolve gitleaks false positive on fixture fake API key ([`9ef398d`](https://github.com/jrollin/cartog/commit/9ef398dec824bfed4ead338d79ef53a9a99ca6d3))
- **ci**: Remove deprecated os and use cross binaries ([`5804ed5`](https://github.com/jrollin/cartog/commit/5804ed55a1a5137abda4b8df00ae90cb88722392))
- **skill**: Add "show me" trigger patterns to cartog skill description ([`fe7020f`](https://github.com/jrollin/cartog/commit/fe7020f18285d3f5902f5b79d73d37e263967e67))
- Update quinn-proto 0.11.13 -> 0.11.14 (RUSTSEC-2026-0037 DoS) ([`68b0399`](https://github.com/jrollin/cartog/commit/68b039901aa99f04e212341610c573e6d3fe7973))
- Do exceed limit description ([`ecd612d`](https://github.com/jrollin/cartog/commit/ecd612d55a44a7587350ea1c2a0a9147196b7d2d))
- Address review findings — chunking, CTE, migration logging ([`3970e5c`](https://github.com/jrollin/cartog/commit/3970e5c69a626c17866ac6027af9c308a9ec17c3))
- Embedding chunking review — UTF-8 safety, false positive filters, docs ([`0907fee`](https://github.com/jrollin/cartog/commit/0907fee98854aab82f0e6d8b166eb1faa42abe1a))
- **plugin**: Restore marketplace.json with distinct name ([`c477286`](https://github.com/jrollin/cartog/commit/c477286cad93682db8bd4bf6c65702693ab0fe7c))

### Documentation

- **skill**: Document cartog search command and progressive narrowing workflow ([`693f47e`](https://github.com/jrollin/cartog/commit/693f47ed25fdabdf5c3f024e3ff7659d29136020))
- Rewrite README to lead with benchmarks and add demo GIF ([`01ea332`](https://github.com/jrollin/cartog/commit/01ea332aef13d8211ce55129b84f592689b82fec))
- Consolidate documentation and add conventions ([`2afcb0a`](https://github.com/jrollin/cartog/commit/2afcb0aa9b42313b87138124ec3d3b570fa17cb8))
- Rewrite tech.md with comprehensive design decisions and rationale ([`71d5a90`](https://github.com/jrollin/cartog/commit/71d5a9080094d4724c742d5d7e3e0820ca90eacd))
- Update README, skill, and project docs for LSP feature ([`10eb869`](https://github.com/jrollin/cartog/commit/10eb86912a239fcd31590565da8920d3a0d2ed7f))
- **skill**: Add CLI/MCP mode detection and usage guidance ([`2361676`](https://github.com/jrollin/cartog/commit/236167632a0dc40bd2242735496993205f2d638f))

### Features

- **perf**: Optimize treesitter parser and sql ([`4746d07`](https://github.com/jrollin/cartog/commit/4746d07e35be8a0e5c8dfbce25a4948c80348b9f))
- Add RAG semantic search, file watcher, and smart search routing ([`ad92a18`](https://github.com/jrollin/cartog/commit/ad92a18ac4685813d0a1424dbbf4dddb983850f6))
- Add java lang support ([`c0c3cc0`](https://github.com/jrollin/cartog/commit/c0c3cc08141bb48a67237f891621594633d482bc))
- Add information about model download on first time ([`3697cb1`](https://github.com/jrollin/cartog/commit/3697cb194db583151e205c13ac0ac85d7f0d75ee))
- Improve AST navigation with query API, richer types, and better edge resolution (#2) ([`e0d8039`](https://github.com/jrollin/cartog/commit/e0d80390a5d08441a563395d9afe54f9c420cb43))
- Add Claude plugin manifest ([`714c29b`](https://github.com/jrollin/cartog/commit/714c29bc5d92d74e9f50e5bcd1d94364b3bb3eab))
- Batch symbol lookup, Rust visibility precision, and docs updates ([`69b52d7`](https://github.com/jrollin/cartog/commit/69b52d7b7fffd00decaf3969dc3bf418fedd3800))
- Add --tokens budget flag and cartog changes command ([`0786420`](https://github.com/jrollin/cartog/commit/0786420558ebe26fd67489b10ab536d09f6fa41b))
- Add in-degree centrality ranking and cartog map command ([`be62b00`](https://github.com/jrollin/cartog/commit/be62b001d3f48910bcabd0ce16d696582e96d946))
- AST-aware embedding chunks with auto-versioned re-embed ([`e6de91d`](https://github.com/jrollin/cartog/commit/e6de91ddca50773e523b8de1e4a1feb10a064e38))
- **rag**: Skip imports from embedding, sort batches by length, bump format v3 ([`de9dce3`](https://github.com/jrollin/cartog/commit/de9dce336ace4801ab0b97dbbdb92e6910ced7a8))
- **skill**: Add version check and version-aware install (#3) ([`0542ff0`](https://github.com/jrollin/cartog/commit/0542ff094463ceb6b9b98696af4881cc3fc0d9ad))
- **lsp**: Add LSP-based edge resolution with persistent MCP server support ([`83e7cbc`](https://github.com/jrollin/cartog/commit/83e7cbcd811f6fb89c2d6fb08d843e2bac0d777b))
- **site**: Add landing page and docs for GitHub Pages ([`3b4e9ef`](https://github.com/jrollin/cartog/commit/3b4e9ef75324c847f051f0e40f591ee80838eccb))

### Miscellaneous

- Add git-cliff changelog generation ([`15c45ac`](https://github.com/jrollin/cartog/commit/15c45ac49ce453167777491d29eb4b08dac140d7))
- Add changelog link to Cargo.toml ([`ca0a9dc`](https://github.com/jrollin/cartog/commit/ca0a9dc70d4450800040baf3a2caaebb377a4b32))
- Remove invalid changelog key from Cargo.toml ([`265fedf`](https://github.com/jrollin/cartog/commit/265fedf88efbe96ef7b8d983fa1b448dc10ba588))
- **ci**: Add security checks ([`3815ee6`](https://github.com/jrollin/cartog/commit/3815ee63a0198674bf2cdb52074766fd03f7624e))
- **ci**: Update cargo deny config ([`39bd314`](https://github.com/jrollin/cartog/commit/39bd3145068d7108759edad8226f8d426c7a3c4b))
- **deps**: Upgrade tree-sitter, notify, rusqlite, rmcp to latest ([`c00701b`](https://github.com/jrollin/cartog/commit/c00701b22c1264c42e12cdd1e1f640287e6378a6))
- **plugin**: Remove marketplace.json and add metadata to plugin.json ([`3fc95e5`](https://github.com/jrollin/cartog/commit/3fc95e50bdd816d43c8dc02281e832dbf21c78ad))

## [0.3.1] - 2026-02-26

### Features

- Add symbol search command and MCP tool ([`7074957`](https://github.com/jrollin/cartog/commit/70749578c50d84ea44e9c8562ddae252b538b84d))

## [0.3.0] - 2026-02-26

### Features

- Add MCP server mode (`cartog serve`) ([`e94f71d`](https://github.com/jrollin/cartog/commit/e94f71da77c2612660f359abd17022d2b7e6cf39))

## [0.2.0] - 2026-02-26

### Bug Fixes

- **skill**: Improve trigger relevancy and add refactoring workflow ([`76cc2b1`](https://github.com/jrollin/cartog/commit/76cc2b1c1fcc032c785c65a069e645cb98434f7e))

### Documentation

- Add Ruby to supported languages in README and skill ([`56f3bf4`](https://github.com/jrollin/cartog/commit/56f3bf4cb326f3d4b1a85fb0c8e56ad259f6539d))

### Testing

- Improve coverage across core extractors and db layer ([`3e2c296`](https://github.com/jrollin/cartog/commit/3e2c2962294dc59cbc73909fa0236223c9e62801))

## [0.1.6] - 2026-02-26

### Features

- Add benchmark suite for measuring cartog token efficiency ([`ba11c54`](https://github.com/jrollin/cartog/commit/ba11c54983b40b945583ce5eb16c902c69674751))
- Add benchmark suite for measuring cartog token efficiency ([`f4a5c90`](https://github.com/jrollin/cartog/commit/f4a5c90ff462d05bc9999f4323d5e0f6b5030117))

## [0.1.5] - 2026-02-25

### Bug Fixes

- Correct documentation inaccuracies and stale references ([`48031f5`](https://github.com/jrollin/cartog/commit/48031f53d62ca2381941374ad95850dd9493a986))

### Features

- Use skill convention to add to favorite ai ide ([`f0df41a`](https://github.com/jrollin/cartog/commit/f0df41afd0eec6d84915c7686a7420eb4ec96f32))

## [0.1.4] - 2026-02-25

### Bug Fixes

- **ci**: Upload coverage to codecov ([`e180884`](https://github.com/jrollin/cartog/commit/e180884d768b734600d781089733ee67e3678b3f))

## [0.1.3] - 2026-02-25

### Bug Fixes

- Release workflow in linux ([`ea55fba`](https://github.com/jrollin/cartog/commit/ea55fba135c6f4b4516676b52437c0d4637314af))

## [0.1.2] - 2026-02-25

### Bug Fixes

- Bump Cargo.toml version from git tag before build and publish ([`3c5707e`](https://github.com/jrollin/cartog/commit/3c5707e70eb1752515df0986a0254f2bd35d1069))
- Release script can be used in mac and linux ([`24f0a5e`](https://github.com/jrollin/cartog/commit/24f0a5eb4529d3ef3e90473b9ec7fc873560c1da))

### Features

- Add release script to bump version, tag, and push ([`6a9cd6b`](https://github.com/jrollin/cartog/commit/6a9cd6b4554aed81d71a059cdd865b16c85479f1))

## [0.1.1] - 2026-02-25

### Bug Fixes

- Wrong repository ([`ac56278`](https://github.com/jrollin/cartog/commit/ac562785f16ab207d28fd9e27388cdd5d8a1434d))

## [0.1.0] - 2026-02-25

### Bug Fixes

- **doc**: Typo in repo link ([`7da0682`](https://github.com/jrollin/cartog/commit/7da068242937635ef3eb2d8f12c98a54211f0677))

### Features

- Initial commit — code graph indexer with CI/CD ([`3163919`](https://github.com/jrollin/cartog/commit/3163919c7f5eb6e56ed1cdf247e4b8c67a3e5b1e))


