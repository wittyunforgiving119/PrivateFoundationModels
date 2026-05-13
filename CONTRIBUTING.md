# Contributing to PrivateFoundationModels

Thanks for thinking about contributing. PFM is small enough that there isn't a huge process — open an issue or PR and we'll talk.

## 🔥 Most useful contribution right now: append your hardware to the bench CSV

The runtime-comparison chart in the README only has one machine on it (M4 Max). Numbers from any other Apple Silicon device — **M1, M2, M3, M4 / Pro / Max / Ultra, iPhone, iPad, Vision Pro** — would dramatically strengthen the comparison. Two-step contribution:

```bash
# 1. Clone, run the bench against the same models we already have rows for.
git clone https://github.com/john-rocky/PrivateFoundationModels
cd PrivateFoundationModels

swift run -c release pfm-bench-apple  --csv-append docs/BENCHMARKS.csv
swift run -c release pfm-bench-coreml --csv-append docs/BENCHMARKS.csv --model qwen3.5-0.8B
swift run -c release pfm-bench-coreml --csv-append docs/BENCHMARKS.csv --model lfm2.5-350m

# MLX needs xcodebuild (Metal shaders), one-time:
xcodebuild -scheme pfm-bench-mlx -configuration Release \
    -destination "platform=macOS" -skipMacroValidation build
$(find ~/Library/Developer/Xcode/DerivedData -name pfm-bench-mlx -path '*Release*' -type f | head -1) \
    --csv-append docs/BENCHMARKS.csv
```

That'll append rows tagged with your CPU brand string (auto-detected via `sysctl`). Want a friendlier name? Pass `--hardware "MacBook Pro M3 Pro 18GB"`.

```bash
# 2. PR.
git checkout -b bench-$(uname -m)-$(date +%Y%m%d)
git add docs/BENCHMARKS.csv
git commit -m "BENCHMARKS: append $(sysctl -n machdep.cpu.brand_string) rows"
gh pr create --title "Bench: $(sysctl -n machdep.cpu.brand_string)" --body "Added bench rows for $(sysctl -n machdep.cpu.brand_string) on macOS $(sw_vers -productVersion)."
```

That's it. I'll re-render the [`runtime-comparison-m4max.png`](docs/media/runtime-comparison-m4max.png) chart once we have ≥ 2 distinct hardware tags so the comparison gets visibly richer.

iPhone / iPad / Vision Pro contributions: see [`Examples/PFMiPhoneBench/`](Examples/PFMiPhoneBench/) for a one-tap SwiftUI runner (lands shortly).

## What's most useful right now

- **New CoreML model entries** for `CoreMLLanguageModel.Catalog`. If you've packaged an `mlboydaisuke/*-coreml` (or compatible) HuggingFace repo that runs via `CoreMLLLM.load(...)`, a one-line catalog addition with a comment about expected tok/s on iPhone is enough.
- **New MLX catalog entries** for `MLXLanguageModel.Catalog` — same shape, `mlx-community/*` repos that `mlx-swift-lm` can load.
- **Vision attachments on Apple FM** when Apple ships a VLM that's accessible from the FoundationModels framework.
- **Transcript reconstruction** through Apple's opaque tool loop (extract `Transcript.ToolCalls` / `ToolOutput` entries from the post-call snapshot and translate back to PFM entries).
- **Grammar-constrained decoding** behind a feature flag (Outlines / LM Format Enforcer style).
- **More verification scenarios** in `PFMDeepKit` — every additional Generable shape or Tool pattern improves backend regression coverage.

## Workflow

1. Fork, branch off `main`, push.
2. `swift test` should stay at 100 % pass.
3. Run the relevant deep harness on real hardware when you touch a backend:
   - `swift run -c release pfm-deep` (CoreML)
   - `pfm-mlx-deep` (xcodebuild; SPM CLI can't compile MLX metal shaders)
   - `swift run -c release pfm-apple-deep` (macOS 26+ with Apple Intelligence)
4. Paste the relevant `docs/*.log` excerpt in the PR description so reviewers can see the result without re-running.
5. Open the PR. No template required, but explain what you changed and why.

## Coding conventions

- Swift 6 language mode (`.swiftLanguageMode(.v6)` is set on every target).
- Public types live in `PrivateFoundationModels`; backends live in `PrivateFoundationModels{Apple,CoreML,MLX}`. The core never imports a backend.
- Names mirror Apple's `FoundationModels` framework wherever the equivalent exists.
- Document the *why*. The *what* should be obvious from the names.

## What's not in scope

- A grammar-based Swift parser for the Apple `@Generable` macro. PFM uses runtime schema translation; that's a deliberate design choice.
- Anything that ships model weights inside the repo. CoreML / MLX backends download on first call.
- Build-system reinventions. Keep it pure SPM.

## Releases

I tag `vX.Y.Z` and cut a GitHub release for each shipped change. Patch versions are for bugfixes and additive catalog entries; minor versions are for new feature surface; major versions wait for an Apple-FM API break.

## Code of conduct

Be kind. Assume good faith. Ship code.

— @JackdeS11
