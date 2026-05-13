# X (Twitter) post — v0.4.0 launch

Account: @JackdeS11
Repo: https://github.com/john-rocky/PrivateFoundationModels
Release: https://github.com/john-rocky/PrivateFoundationModels/releases/tag/v0.4.0

## Tweet 1 (the hook)

> PrivateFoundationModels v0.4 — one Swift call site, three on-device backends.
>
> The same `LanguageModelSession.respond(to:)` runs:
> · iOS 26 → Apple's native FoundationModels (Apple Intelligence)
> · iOS 18 → CoreML on the Neural Engine
> · iOS 17 → MLX on the GPU
>
> Drop-in source-compatible with Apple FM.

(Attach demo gif: docs/media/pfm.gif. If a fresh video showing the Apple passthrough is easier, screen-record the pfm-apple-smoke log scrolling — 8 seconds is plenty.)

## Tweet 2 (the proof)

> Verified on macOS 26.0 — Apple's actual on-device model answered through my package's API in 1.2 s:
>
> ```
> 1. respond(to:) ✓ 1209 ms
> "The capital of France is Paris."
> 2. streamResponse(to:) ✓
> ```
>
> Same code falls back to CoreML/MLX on iOS 18 with zero changes. Log: docs/pfm-apple-smoke.log

## Tweet 3 (the install)

> ```swift
> import PrivateFoundationModels
> import PrivateFoundationModelsApple
>
> if #available(iOS 26.0, *), AppleFoundationModel.isAvailable {
>     SystemLanguageModel.default = SystemLanguageModel(
>         backend: AppleFoundationModel.load()
>     )
> }
>
> let session = LanguageModelSession(instructions: "Be brief.")
> print(try await session.respond(to: "Capital of France?").content)
> ```

## Tweet 4 (the why)

> Why ship this?
>
> 1. Apple FM is gated to iOS 26. PFM gives you the same surface on iOS 18.
> 2. Apple FM is locked to Apple's 3 B model. PFM also lets you swap to Gemma 4 / Qwen3.5 / LFM2.5 / Llama 3.2 / any mlx-community model.
> 3. The day you bump to iOS 26 you can either keep PFM (older-OS support + your own models) or `s/PrivateFoundationModels/FoundationModels/`.

## Tweet 5 (the link)

> Verified: 90/90 stub tests + 5 real-model harnesses (PASS 23 / MODEL 9 / FAIL 0).
>
> MIT license. SPM only.
>
> https://github.com/john-rocky/PrivateFoundationModels
>
> Built by @JackdeS11 (ex-Ultralytics, Pebble Inc.). Hugely indebted to @apple's FoundationModels team and @AwniHannun / @mxlchart on the MLX side.

---

## Alternate single tweet (if you want one fire-and-forget post)

> PrivateFoundationModels v0.4 is out.
>
> Same `LanguageModelSession.respond(to:)` call site, three runtimes:
> · iOS 26+: Apple's native FoundationModels (Apple Intelligence)
> · iOS 18+: CoreML on the ANE
> · iOS 17+: any mlx-community/* model on the GPU
>
> Drop-in source-compatible with Apple FM. MIT.
>
> github.com/john-rocky/PrivateFoundationModels
