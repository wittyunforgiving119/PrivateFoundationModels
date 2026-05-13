# Apple Developer Forums post — v0.5.x launch

Forum: **Foundation Models** category (or **Apple Intelligence**).

## Title

`PrivateFoundationModels: source-compatible FoundationModels API on iOS 18, native passthrough on iOS 26`

## Body

I built a Swift package that mirrors Apple's `FoundationModels` framework surface so iOS-18-era apps can write Apple-FM-shaped code today and graduate to the native framework when their deployment target reaches iOS 26 — without rewriting any of the call sites.

**Repo:** https://github.com/john-rocky/PrivateFoundationModels

The same `LanguageModelSession.respond(...)` call routes to one of three on-device runtimes depending on what's available:

- **iOS 26+ / macOS 26+** — Apple's actual native FoundationModels (Apple Intelligence). The `PrivateFoundationModelsApple` product is a thin passthrough; Apple's model does the work.
- **iOS 18+** — CoreML on the Apple Neural Engine via [`john-rocky/CoreML-LLM`](https://github.com/john-rocky/CoreML-LLM). LFM2.5, Gemma 4 (incl. E2B multimodal), Qwen3.5, Qwen3-VL, FunctionGemma, EmbeddingGemma.
- **iOS 17+** — MLX-Swift via [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm). Any `mlx-community/*` repo — Llama, Qwen, Gemma, Mistral, Phi, including the VLM-class `*-VL-*` models.

`@Generable` structured output and `Tool` calling work on all three. `pfm-apple-deep` on macOS 26.0 / Xcode 26.1.1 runs PASS 14 / MODEL 0 / FAIL 0 against Apple's native model with the full Generable × Tool × Multimodal × PromptBuilder matrix.

### Source compatibility

Code written against Apple's `FoundationModels` compiles unchanged against PrivateFoundationModels — only the import line and the backend install at app startup differ. See [`Examples/PFMPortability/AppleFMCode.swift`](https://github.com/john-rocky/PrivateFoundationModels/blob/main/Examples/PFMPortability/AppleFMCode.swift) for ten Apple-FM-shaped call sites that compile and run unchanged against the package.

When your deployment target reaches iOS 26 you can either delete the package (`s/PrivateFoundationModels/FoundationModels/`) or keep it for the older-OS support and the bring-your-own-model story.

### Where I'd love feedback

- API mismatch reports: anywhere PFM's surface diverges from what Apple ships (initializer shapes, parameter labels, etc.). I want to keep it byte-compatible.
- Adapter / fine-tune ergonomics: PFM lets you swap to your own model but the adapter loading story is still ad-hoc per backend; an Apple-FM-`Adapter`-shape would be useful.
- Behavior gaps: places where Apple's framework does something PFM doesn't replicate.

MIT license, SPM only. No model files in the repo — backends download on first call (Apple FM uses the OS-bundled model).

— Daisuke (@JackdeS11 / john-rocky)
