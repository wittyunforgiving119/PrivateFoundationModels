# PFMiPhoneBench

One-tap iPhone bench app. Open it, tap **Run all**, leave the device alone for ~5 minutes, harvest the CSV.

## What it benches

Sequential, with explicit release-before-load between backends so the 8 GB RAM iPhone class can handle it:

1. **Apple FoundationModels** — iOS 26+ with Apple Intelligence enabled (skipped otherwise).
2. **CoreML / ANE** — LFM2.5-350M (~810 MB).
3. **CoreML / ANE** — Qwen3.5-0.8B (~1.2 GB).
4. **MLX / GPU** — mlx-community/Qwen3.5-0.8B-MLX-4bit (~500 MB).

Each plan: download on first run, load, warmup, three timed iterations of the standard `pfm-bench` prompt + `GenerationOptions(temperature: 0.0, maximumResponseTokens: 80)`. Median taken.

## Output

When the run completes, the app:

1. Renders a result card per backend (load_ms, ttft_ms, total_ms, chars, chars/sec).
2. Writes a `pfm-bench-<timestamp>.csv` file into the app's Documents directory (visible in the Files app under "On My iPhone / PFMiPhoneBench").
3. Copies the same CSV to the system clipboard.
4. Offers a **Share CSV** button that hands the data to `UIActivityViewController` — AirDrop to your Mac is the fastest harvest path.

## Build + run

```bash
cd Examples/PFMiPhoneBench
xcodegen   # regenerate PFMiPhoneBench.xcodeproj from project.yml
open PFMiPhoneBench.xcodeproj
```

In Xcode:

1. Pick a real iPhone (simulator won't have Apple Intelligence; MLX Metal works there but tokens/sec is meaningless).
2. Sign in Signing & Capabilities → pick your team.
3. ⌘R.

First run will download three model bundles (CoreML LFM2.5 + Qwen3.5 to Application Support, MLX Qwen3.5 to HuggingFace cache). Roughly 2.5 GB total over the network. Subsequent runs are cache hits.

## Hand-off mode

The app is designed for one-tap unattended runs. Once "Run all" is tapped:

- The screen stays awake during the bench (UIApplication idle timer is left on by default, but the app's foreground prevents auto-lock).
- No user interaction needed until "Done — CSV copied + saved" appears.
- Background mode is requested (`UIBackgroundModes: processing`) so a brief switch to another app doesn't kill the run — but **keep the screen on for fastest results**, the OS de-prioritizes background-processing tasks.

## Contributing your iPhone's numbers

After Run all completes:

1. AirDrop the CSV to your Mac (Share → AirDrop) — or open the CSV in Files → On My iPhone.
2. Append it to `docs/BENCHMARKS.csv` in the repo:
   ```bash
   cat ~/Downloads/pfm-bench-*.csv | tail -n +2 >> docs/BENCHMARKS.csv
   ```
3. PR. The maintainer (`@john-rocky`) re-renders the chart.

See [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for the umbrella workflow.
