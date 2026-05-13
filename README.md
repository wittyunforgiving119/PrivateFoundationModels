# PrivateFoundationModels

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fjohn-rocky%2FPrivateFoundationModels%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/john-rocky/PrivateFoundationModels)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fjohn-rocky%2FPrivateFoundationModels%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/john-rocky/PrivateFoundationModels)
[![CI](https://github.com/john-rocky/PrivateFoundationModels/actions/workflows/ci.yml/badge.svg)](https://github.com/john-rocky/PrivateFoundationModels/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**One Swift call site. Three on-device runtimes. The same `LanguageModelSession.respond(...)` reaches Apple Intelligence on iOS 26, CoreML on iOS 18, or any `mlx-community/*` model on the GPU — your code never changes.**

<p align="center">
  <a href="docs/RUNTIME_COMPARISON.md">
    <img src="docs/media/runtime-comparison-m4max.png" alt="Same Qwen3.5-0.8B on M4 Max: MLX/GPU 4-bit is 12× TTFT and 5× throughput vs CoreML/ANE FP16." width="820">
  </a>
</p>

<p align="center"><em>Same model, same prompt, same call site — different runtime. M4 Max numbers. <a href="docs/RUNTIME_COMPARISON.md">Full table + caveats.</a></em></p>

## 30-second value prop

```swift
import PrivateFoundationModels
import PrivateFoundationModelsApple    // iOS 26+ — Apple Intelligence
import PrivateFoundationModelsCoreML   // iOS 18+ — Apple Neural Engine
import PrivateFoundationModelsMLX      // iOS 17+ — Apple GPU, any mlx-community/* model

// Pick a backend at startup. Everything below this is byte-identical to Apple's
// FoundationModels framework.
if #available(iOS 26.0, macOS 26.0, *), AppleFoundationModel.isAvailable {
    SystemLanguageModel.default = SystemLanguageModel(backend: AppleFoundationModel.load())
} else {
    SystemLanguageModel.default = SystemLanguageModel(
        backend: try await CoreMLLanguageModel.load(.lfm2_5_350M))
}

let session = LanguageModelSession(instructions: Instructions("Be brief."))
print(try await session.respond(to: "Capital of France?").content)
// "The capital of France is Paris."  — from Apple's actual on-device model on iOS 26,
// or from LFM2.5-350M on the Apple Neural Engine on iOS 18. Your call site doesn't know.
```

`@Generable`, `Tool`, `@PromptBuilder`, streaming, transcripts — all the Apple FM 26 surface, end-to-end verified across all three backends (see [Verified](#verified) below).

## The story

Apple shipped FoundationModels with iOS 26. It only runs on iOS 26. It only runs Apple's 3 B on-device model. If you ship an app that has to run today on iOS 18 — or you want to use your own model — you're stuck.

PFM is the **iOS 18 polyfill that becomes a runtime passthrough on iOS 26**. The same Apple-FM-shaped code compiles unchanged, runs against:

| Backend | Product | iOS | Model |
|---|---|---|---|
| Apple FoundationModels | `PrivateFoundationModelsApple` | **iOS 26+** | Apple's 3 B on-device LLM (no download, ships in the OS) |
| CoreML / Apple Neural Engine | `PrivateFoundationModelsCoreML` | iOS 18+ | LFM2.5, Gemma 4, Qwen3.5, Qwen3-VL, FunctionGemma, EmbeddingGemma |
| MLX / Apple GPU | `PrivateFoundationModelsMLX` | iOS 17+ | Any `mlx-community/*` repo: Llama, Qwen, Gemma, Mistral, Phi, plus VLMs |

The day your deployment target reaches iOS 26 you can either:
- `s/PrivateFoundationModels/FoundationModels/` and delete the package, or
- Keep it for the older-OS support and the bring-your-own-model story.

Either way your `@Generable` types, `Tool` instances, and `respond(...)` call sites don't change.

## Install

```swift
// Package.swift
.package(url: "https://github.com/john-rocky/PrivateFoundationModels", from: "0.10.4"),
```

Pick the backend products you need. Everything is pure SPM; no model files in the repo (they download on first call).

## Tutorial

The 5-minute walkthrough — `swift package init` to streaming `@Generable`: **[`docs/TUTORIAL.md`](docs/TUTORIAL.md)**.

Already on Apple FM and want to backport to iOS 18: **[`docs/MIGRATING_FROM_APPLE_FM.md`](docs/MIGRATING_FROM_APPLE_FM.md)** — a five-step recipe.

## OpenAI-compatible local HTTP API (v0.7.0+)

Expose any PFM backend over the OpenAI HTTP shape so non-Swift codebases (Python, Node, curl, the official OpenAI SDKs) can drive Apple's on-device model unchanged:

```bash
swift run -c release pfm-serve-apple
# [pfm-serve] listening on http://127.0.0.1:11434
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:11434/v1", api_key="not-required")

resp = client.chat.completions.create(
    model="apple-fm",
    messages=[{"role": "user", "content": "Capital of France?"}],
)
# resp.choices[0].message.content == "The capital of France is Paris."
```

Implemented endpoints: `POST /v1/chat/completions` (with SSE streaming, tool calling, vision content arrays, JSON mode), `POST /v1/completions`, `POST /v1/embeddings`, `GET /v1/models`, `GET /healthz`, full CORS for browser `fetch()`. Multi-model loading (Ollama-style) since v0.10.0:

```bash
pfm-serve-mlx \
  --model mlx-community/Qwen3.5-0.8B-MLX-4bit \
  --model mlx-community/FastVLM-0.5B-bf16 \
  --embedding-model sentence-transformers/all-MiniLM-L6-v2
```

End-to-end verified against the official `openai==2.36` SDK including streaming tool calls and embeddings. Demos in [`Examples/PythonClient/`](Examples/PythonClient/).

## Benchmarks

Standardized `pfm-bench` harness with median-of-3 + warmup. Apples-to-apples cross-runtime numbers on M4 Max, multi-language coverage across en/es/ko/ja/zh, contributable from any Mac with one command:

```bash
swift run -c release pfm-bench-apple  --csv-append docs/BENCHMARKS.csv
swift run -c release pfm-bench-coreml --csv-append docs/BENCHMARKS.csv --model qwen3.5-0.8B
# MLX needs xcodebuild
$(find ~/Library/Developer/Xcode/DerivedData -name pfm-bench-mlx -path '*Release*' -type f | head -1) \
  --csv-append docs/BENCHMARKS.csv
```

[`docs/BENCHMARKS.csv`](docs/BENCHMARKS.csv) grows per-contributor. iPhone numbers can be appended via the [`Examples/PFMiPhoneBench/`](Examples/PFMiPhoneBench/) one-tap iOS app.

Deep dives:
- **[`docs/RUNTIME_COMPARISON.md`](docs/RUNTIME_COMPARISON.md)** — same model, three runtimes
- **[`docs/MULTILANG_BENCH.md`](docs/MULTILANG_BENCH.md)** — same task, five languages
- **[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)** — full methodology

## Verified

Captured on Apple M4 Max / macOS 26.0 / Xcode 26.1.1, against `mlboydaisuke/lfm2.5-350m-coreml`, `mlx-community/Qwen3.5-0.8B-MLX-4bit`, `mlx-community/FastVLM-0.5B-bf16`, `sentence-transformers/all-MiniLM-L6-v2`, and Apple's own on-device model:

| Harness | What it proves | Result |
|---|---|---|
| `swift test` | Session logic, schema decoder, tool dispatch, error wrapping — stub-backed for determinism | **94 / 94 pass** |
| `pfm-verify` | Every public API path against a real CoreML model | **10 / 10 pass** ([log](docs/pfm-verify.log)) |
| `pfm-portability` | Real Apple-FM-shaped code compiled and ran unchanged | **8 / 8 pass** ([log](docs/pfm-portability.log)) |
| `pfm-deep` | Every Generable shape × Tool pattern against CoreML | **PASS 7 / MODEL 4 / FAIL 0** ([log](docs/pfm-deep.log)) |
| `pfm-mlx-deep` | Same matrix routed through MLX-Swift | **PASS 9 / MODEL 5 / FAIL 0** ([log](docs/pfm-mlx-deep.log)) |
| `pfm-apple-deep` | Same matrix through Apple's native FoundationModels | **PASS 14 / MODEL 0 / FAIL 0** ([log](docs/pfm-apple-deep.log)) |
| `pfm-apple-smoke` | `respond` + `streamResponse` + `Generable` through Apple FM | ✓ load 0 s · respond 0.7 s · stream ([log](docs/pfm-apple-smoke.log)) |
| `pfm-vision-sample` | OpenAI content array → MLX VLM (FastVLM-0.5B) end-to-end | ✓ identified red top-left, green top-right ([log](docs/pfm-vision-sample.txt)) |
| `pfm-embeddings-sample` | OpenAI `/v1/embeddings` → MLXEmbedder (MiniLM-L6-v2) | ✓ 384-dim, semantic ranking correct ([log](docs/pfm-embeddings-sample.txt)) |

Plus 6 captured runs through the openai Python SDK driving the HTTP server — chat, streaming, function calling, streaming tool calls, vision content arrays, embeddings — all in [`Examples/PythonClient/`](Examples/PythonClient/).

## Bring your own backend

`LanguageModelBackend` is two methods (`generate` + `streamGenerate`) plus an availability property. Route to llama.cpp, a remote API, your own runtime — see [`Sources/PrivateFoundationModels/LanguageModelBackend.swift`](Sources/PrivateFoundationModels/LanguageModelBackend.swift).

## Compatibility with `FoundationModels`

PFM mirrors Apple's FoundationModels API surface as of WWDC 2025 / iOS 26.1:

- `LanguageModelSession` — `respond(to:)`, `respond(to:generating:)`, `streamResponse(to:)`, `streamResponse(to:generating:)`, `prewarm()`, `transcript`, `isResponding`, `image:` overloads.
- `Instructions`, `GenerationOptions`, `SamplingMode`.
- `Response<Content>`, `ResponseStream<Content>` (AsyncSequence with `Snapshot`).
- `Transcript` + `Transcript.Entry` (Codable).
- `Tool` protocol, `AnyTool` type-erased wrapper, two-turn tool calling.
- `Generable` protocol + macro, `GenerationSchema`, `@Guide(description:)`.
- `SystemLanguageModel` + `Availability` + `UnavailableReason`, `UseCase`, `Adapter`.
- `Prompt` + `@PromptBuilder` + `@InstructionsBuilder`.
- `Guardrails` (default accept-all; Apple FM passthrough delegates to Apple's).
- `GenerationError` with cases matching Apple's where they exist.

If you find a method or initializer in Apple's docs that PFM doesn't ship, **[open an issue](https://github.com/john-rocky/PrivateFoundationModels/issues/new)**.

## What this package is not

- **Not affiliated with Apple.** "Foundation Models" is Apple's trademark; this is an API-compatible alternative.
- **Not a model.** It's a thin Swift surface that delegates to whatever backend you wire up.
- **Not a grammar-constrained sampler** on CoreML / MLX. `@Generable` is enforced via system-prompt + post-processing; on retry the schema is re-injected. Apple FM uses Apple's native grammar sampler. Grammar-constrained MLX sampling is on the roadmap.

## Examples

- [`Examples/PythonClient/`](Examples/PythonClient/) — official `openai` SDK driving pfm-serve. Chat, streaming, function calling, vision, embeddings.
- [`Examples/PFMSwitcher/`](Examples/PFMSwitcher/) — production-shaped iOS chat app with backend switching and strict release-before-load memory management.
- [`Examples/PFMiPhoneBench/`](Examples/PFMiPhoneBench/) — one-tap iPhone bench app. CSV harvest via AirDrop.

## Roadmap

The current head is **v0.10.4**. Full version history in [`CHANGELOG.md`](CHANGELOG.md). Next on the list:

- Grammar-constrained sampling on MLX (closes the last "Not a..." disclaimer above).
- Qwen3-VL stateful routing on CoreML.
- `llama.cpp` / GGUF backend.
- Multi-machine bench fill-in (M1 / M2 / M3 / iPhone / iPad / Vision Pro) — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Author

[Daisuke Majima](https://github.com/john-rocky) ([@JackdeS11](https://x.com/JackdeS11)) — founder of [Pebble Inc.](https://pebble.co.jp), maintainer of [`CoreML-Models`](https://github.com/john-rocky/CoreML-Models) (1.7k★), [`CoreML-LLM`](https://github.com/john-rocky/CoreML-LLM), and the [`mlboydaisuke`](https://huggingface.co/mlboydaisuke) Apple Silicon model collection.

Open to consulting on Apple Silicon LLM inference and on-device deployment — [pebble.co.jp](https://pebble.co.jp).

## License

MIT. See [LICENSE](LICENSE). Model weights inherit their own licenses (Gemma: Gemma Terms; Qwen: Apache 2.0; LFM2.5: LFM Open License v1.0).
