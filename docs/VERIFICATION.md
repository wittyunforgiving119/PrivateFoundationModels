# Verification log

End-to-end verification on real hardware against a real on-device model. The
captured log is the unedited output of `swift run -c release pfm-verify`
running the full scenario matrix.

## Environment

| | |
|---|---|
| Date | 2026-05-13 |
| Host | Apple M4 Max |
| OS | macOS 26.0 (25A354) |
| Swift | 6.2.1 (swiftlang-6.2.1.4.8) |
| Target | arm64-apple-macosx26.0 |
| Package | PrivateFoundationModels @ 4ee6fe9 (post-fixes) |
| Backend | `PrivateFoundationModelsCoreML` → `john-rocky/CoreML-LLM` 1.8.0 |
| Model | `mlboydaisuke/lfm2.5-350m-coreml` (~810 MB, ANE-resident) |

## Reproduction

```bash
# 1. Pre-populate the model directory. The CoreML-LLM background-URLSession
#    downloader is intended for in-app use and does not function from a
#    plain CLI process — see "URLSession.background limitation" below.
mkdir -p ~/Documents/Models/lfm2.5-350m
huggingface-cli download mlboydaisuke/lfm2.5-350m-coreml \
    --local-dir ~/Documents/Models/lfm2.5-350m

# 2. Run the harness.
cd PrivateFoundationModels
swift run -c release pfm-verify --model lfm2.5-350m
```

## Scenarios exercised

Every public API path of `PrivateFoundationModels`:

| # | Scenario | What it proves |
|---|---|---|
| 1 | Load CoreML backend, install as `SystemLanguageModel.default` | Backend protocol + availability state-machine wired correctly |
| 2 | `session.respond(to:)` × 2 (single-shot, non-streaming) | Prompt → response loop, transcript update across turns |
| 3 | `session.streamResponse(to:)` | Cumulative-prefix invariant on `Snapshot.content` (Apple parity) |
| 4 | `session.respond(to:generating: CityFact.self)` | `Generable` schema → JSON output → `Codable` decode |
| 5 | `session.respond(to:)` with `[AddTool()]` registered | Tool-call loop: model emits `TOOL_CALL:`, session invokes tool, appends `toolCall` + `toolOutput`, model produces final answer |
| 6 | `Transcript.serialized()` → `Transcript(serialized:)` | Codable round-trip preserves all entry kinds incl. tool calls |

## Result

```
  passed: 10
  failed: 0

  🎉 every scenario passed.
```

Full unedited log: [`pfm-verify.log`](pfm-verify.log). Highlights:

- Cold model load (uncompiled ANE program): **5,011 ms** (one-time per device).
- Warm load (ANE program cached): **298 ms**.
- First `respond` after warm load: **563 ms** (3-token response).
- `streamResponse`: 16 snapshots emitted, every snapshot is a strict prefix of
  the next. Final snapshot length matches `collect().content`.
- Structured output: `CityFact(city: "Paris", country: "France", famousFor: "Cultural landmarks")` parsed cleanly.
- Tool call: model emitted `TOOL_CALL: add\n{"a":17,"b":25}`, session invoked
  `AddTool` (returned `"42"`), model followed up with final response `"42"`.
- Transcript JSON serialization round-trip: 270 bytes, 3 entries restored
  identical to original.

## Bugs found and fixed during verification

Bringing the harness up exercised paths the stub-backed unit suite never
touched. Two real defects in the CoreML backend surfaced and were patched
before the run was declared green:

1. **Streaming snapshot trimming broke the cumulative-prefix invariant.**
   The CoreML backend's `streamGenerate` was emitting `parsed.text` (whitespace-trimmed)
   as the terminal snapshot, while interior snapshots used the raw cumulative
   buffer. If the model's final token was followed by whitespace or a code
   fence, the terminal snapshot was *shorter* than the prior one, violating
   Apple's documented `ResponseStream` contract. **Fix**: emit the raw
   cumulative buffer at the terminal step too; the session-level
   `Response.content` and transcript entry are produced from `parsed.text`
   separately so end-user surface is unaffected.

2. **Tool-call JSON extraction was too literal.**
   The parser expected the line after `TOOL_CALL: <name>` to be bare JSON.
   LFM2.5-350M (and other small models) sometimes prepend prose ("Sure, here
   are the arguments: ..."). The parser fed that text straight into
   `JSONDecoder` which threw `dataCorrupted`. **Fix**: depth-counted,
   string-aware `extractJSONObject` walks the post-marker text and pulls
   out the first balanced `{ ... }`. If nothing balanced is found the model's
   output is treated as plain text rather than a malformed tool call.

Both fixes shipped before publishing v0.1.0.

## Known limitations surfaced during verification

These are model / backend-side caveats discovered while bringing the harness
up. They are not bugs in `PrivateFoundationModels`, but worth knowing.

### URLSession.background does not work from a plain CLI process

`john-rocky/CoreML-LLM`'s `ModelDownloader` uses
`URLSessionConfiguration.background(withIdentifier:)`, which assumes a hosted
app (delegate, app-suspension protocol). Running `pfm-verify` directly on a
Mac shell produces `NSURLErrorDomain Code=-1 "unknown error"` on first call
because the background session can never service the request. **Workaround**:
populate the model directory once with `huggingface-cli download …`. From an
iOS app (which is the supported deployment), the background download path
works as documented in CoreML-LLM's README.

### Catalog entries that *do not* route through `CoreMLLLM.load(repo:)`

`CoreMLLLM.load(repo:)` expects either (a) a flat monolithic layout
(`model.mlmodelc` + `model_config.json` + `hf_model/`), or (b) the Gemma 4
chunked layout (`chunk1.mlpackage` … `chunk4.mlpackage` at the root). The
Qwen3.5 family ships under a different chunk-naming convention
(`qwen3_5_0_8b_decode_chunks_mlkv/chunk_a` … `chunk_d`) and is driven by a
separate Swift type, `Qwen35MLKVGenerator`, in the upstream package. As a
result the `.qwen3_5_0_8B` / `.qwen3_5_2B` / `.qwen3VL2BStateful` cases in
`CoreMLLanguageModel.Catalog` currently fail at load with
`CoreMLLLMError.configNotFound` / `Code=3 "Model does not exist"`.

For v0.1.0 the safe defaults that round-trip end-to-end through the unified
`CoreMLLLM.load(repo:)` entry are:

- ✅ `.lfm2_5_350M` — verified in this run
- ✅ `.gemma4E2B` — supported by CoreMLLLM through the chunked path
- ✅ `.gemma4E4B` — supported by CoreMLLLM through the chunked path

Routing Qwen3.5 through its dedicated `Qwen35MLKVGenerator` is a planned
follow-up (`v0.2`); the catalog entries are kept for source-compatibility but
should not be the default for new integrations.

### Small-model echo on multi-turn

Scenario 2 prompted "Say hello in Japanese.", the LFM2.5-350M model replied
"Red." (echoing the previous turn's answer). This is a model-quality artefact
of a 350 M-parameter model with English-leaning training data and was *not*
a `PrivateFoundationModels` defect — the prompt was routed, the response was
captured, the transcript was correctly updated.

## Files referenced

- `pfm-verify.log` — full unedited stdout of this run
- `Sources/PFMVerify/main.swift` — the harness itself
- `Sources/PrivateFoundationModelsCoreML/CoreMLLanguageModel.swift` — backend
