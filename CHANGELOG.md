# Changelog

All notable changes to PrivateFoundationModels will be documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0-beta.1] — 2026-05-13

### Added
- `Qwen3Backend`: a `LanguageModelBackend` that drives Qwen3.5 0.8B / 2B
  through CoreML-LLM's `Qwen35MLKVGenerator` ANE path. The Qwen catalog
  entries that returned `configNotFound` / "model does not exist" in v0.1
  now load and generate end-to-end (`pfm-verify --model qwen3.5-0.8B` →
  9/10 PASS; the one remaining miss is model-quality, not framework —
  Qwen3.5 0.8B occasionally emits a JSON array where a string-typed
  Generable field is required, and the framework correctly raises
  `decodingFailure`).
- `CoreMLLanguageModel.Catalog.tokenizerSourceRepo`: maps a CoreML repo
  to the upstream HuggingFace repo it borrows its tokenizer from.
  Used internally so the foreground fetcher pulls `tokenizer.json` +
  `tokenizer_config.json` from `Qwen/Qwen3.5-0.8B` (etc.) when the
  mlboydaisuke CoreML repo doesn't include them.
- `HFFetcher.ensureFiles(_:repo:in:token:onProgress:)`: download a
  hand-picked list of files from any HF repo. Backs the tokenizer
  pull-down above.
- Retry loop on transient `URLSession` errors in `HFFetcher`
  (`NSURLErrorNetworkConnectionLost`, `NSURLErrorTimedOut`, etc.) with
  exponential backoff. HF's Xet LFS backend drops multi-GB downloads
  often enough that this matters in practice.
- `JSONExtraction.stripThinkBlocks`: removes `<think>...</think>` and
  `<thinking>...</thinking>` reasoning preambles so the downstream JSON
  / tool-call extraction sees the model's final answer. Qwen3 family is
  the immediate motivation; future DeepSeek-R1 / o1-style models would
  use the same path.

### Changed
- `CoreMLLanguageModel.load(...)` return type went from
  `CoreMLBackendImpl` to `any LanguageModelBackend` so the function can
  return either a `CoreMLBackendImpl` (LFM2.5 / Gemma 4) or a
  `Qwen3Backend` (Qwen3.5). All real-world call sites pipe the return
  value into `SystemLanguageModel(backend:)`, which takes
  `any LanguageModelBackend`, so the change is source-compatible at
  every documented usage. `pfm-verify` adjusted to cast when it wants
  CoreML-specific introspection (`underlying.contextLength`).
- Tool-call parser is now layout-tolerant: accepts
  `TOOL_CALL: name\n{json}`, `TOOL_CALL: name {json}`, and
  `TOOL_CALL: {json}` (with single-tool name inference). The tool name
  is taken as the first whitespace-delimited token before the `{` —
  previous versions kept all interior whitespace and broke on
  small-model output like `TOOL_CALL: add\nSINGLE-LINE JSON arguments:`.

### Known limitations
- `.qwen3VL2BStateful` still doesn't load — vision input on the session
  API ships in v0.3.
- Reasoning models (Qwen3 family) need a generous `maximumResponseTokens`
  budget for `Generable` because the `<think>` preamble eats into the
  budget. v0.2 doesn't expose a "thinking off" toggle; `pfm-verify`
  bumps the Generable budget to 768 tokens for the qwen3.5 case as a
  workaround.

## [0.1.1] — 2026-05-13

### Added
- `@Generable` macro (member + extension attached) that walks a struct's
  stored properties and synthesizes `static var generationSchema`. Drop-in
  shape with Apple's `FoundationModels.Generable` macro: supports
  primitives, optional fields (which drop out of `required`), `[T]` arrays,
  nested `@Generable` types, and macro-level `description:` argument.
- `@Guide(description:)` peer attribute for per-field schema descriptions.
- `HFFetcher`: a foreground-`URLSession` HuggingFace tree mirror used by
  `CoreMLLanguageModel.load(...)` so the first call downloads on its own
  from any plain-process context (CLI, Xcode Preview, unit tests).
  CoreML-LLM upstream's background-`URLSession` downloader is bypassed.
- `CoreMLLanguageModel.load(_:cacheDirectory:hfToken:onProgress:)` with
  new parameters for custom cache root and gated-repo authentication.
- `defaultCacheDirectory(for:)` static helper exposing the cache root.
- New `PFMMacros` macro target backed by `swift-syntax 600.0`.
- 11 new tests (`GenerableMacroTests`) covering primitive / optional /
  array / nested / `@Guide` / macro-description / end-to-end paths.

### Changed
- `PFMPortability/AppleFMCode.swift` now uses `@Generable` and
  `@Guide(description:)` — the portability proof's structured-output
  fixture is now byte-identical to canonical Apple FM sample code.
- README documents `@Generable` as the recommended path; manual
  `generationSchema` is now an opt-out.

### Fixed
- Streaming `Generable` decode path now strips Markdown code fences
  through the shared `JSONExtraction` helper, matching the non-streaming
  path. (First surfaced in `pfm-deep`.)
- Streaming `Generable` decode now wraps `Swift.DecodingError` as
  `GenerationError.decodingFailure` — consistent error surface with
  `respond(to:generating:)`.

## [0.1.0] — 2026-05-13

Initial release.

### Added
- `LanguageModelSession` with `respond(to:)`, `respond(to:generating:)`,
  `streamResponse(to:)`, `streamResponse(to:generating:)`, `prewarm()`,
  `transcript`, `isResponding`.
- `Instructions`, `GenerationOptions`, `SamplingMode`.
- `Response<Content>` and `ResponseStream<Content>` (cumulative snapshots).
- `Transcript` with `Entry` kinds `instructions` / `prompt` / `response` /
  `toolCall` / `toolOutput`, Codable round-trip via `serialized()` /
  `init(serialized:)`.
- `Tool` protocol + `AnyTool` type-erased wrapper, plus
  `LanguageModelSession(tools: [any Tool], ...)` convenience initializer.
- `Generable` protocol with `GenerationSchema` (recursive JSON-Schema-shaped),
  primitives conforming out of the box.
- `SystemLanguageModel` with `.default` (thread-safe, settable), pluggable
  `LanguageModelBackend` protocol.
- `GenerationError` matching Apple's case names: `concurrentRequests`,
  `refusal`, `decodingFailure`, `exceededContextWindowSize`, `unavailable`,
  `cancelled`, `backend`.
- `PrivateFoundationModelsCoreML` product: `CoreMLLanguageModel` factory
  wrapping `john-rocky/CoreML-LLM` with a 7-model catalog covering
  `mlboydaisuke/*` HuggingFace repos.
- `PFMChat` example iOS app (~200 lines, SwiftUI).
- 30 unit tests covering API surface and session behavior.

### Fixed during verification
- CoreML backend streaming: terminal snapshot was trimmed which broke
  Apple's documented cumulative-prefix invariant. Terminal snapshot now
  carries the same raw cumulative buffer as interior snapshots.
- CoreML backend tool-call JSON extraction: parser was too literal and
  rejected output where the model prepended prose to the JSON object.
  Replaced with a depth-counted, string-aware extractor that finds the
  outermost balanced `{ ... }`.

### Known limitations
- No `@Generable` macro yet — conformers supply `generationSchema` by hand.
- Schema-constrained generation is enforced via system-prompt instructions and
  post-processing, not via a grammar-constrained sampler. Use a backend that
  supports a constrained sampler (Apple FM's grammar mode, Outlines, LM Format
  Enforcer) for deterministic schema enforcement.
- Tool calling uses a `TOOL_CALL: name\n{json}` text protocol the model is
  asked to follow; robustness depends on the underlying model.
- The Qwen3.5 / Qwen3-VL catalog entries do not load through this backend in
  v0.1 — CoreML-LLM ships those families behind a separate Swift type
  (`Qwen35MLKVGenerator`). Verified safe catalog entries: `.lfm2_5_350M`,
  `.gemma4E2B`, `.gemma4E4B`. See `docs/VERIFICATION.md`.
- `CoreMLLLM.ModelDownloader` uses `URLSessionConfiguration.background` and
  does not run from a plain CLI process. From an iOS app context it works as
  documented in CoreML-LLM's README; for CLI / Mac verification pre-populate
  `~/Documents/Models/<id>/` with `huggingface-cli download`.
- No vision input on the `LanguageModelSession` API yet. The CoreML backend
  can run Qwen3-VL / Gemma 4 multimodal via `CoreMLLLM` directly but the
  typed surface for image prompts is on the v0.6 roadmap.
- No streaming partial-JSON decode for `Generable` types other than fully
  parseable prefixes. Mid-stream snapshots are emitted only when the
  accumulated JSON parses as the target type.
