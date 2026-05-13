# Migrating from `FoundationModels` to PrivateFoundationModels

You've already shipped (or prototyped) code against Apple's `FoundationModels` framework on iOS 26 and want to bring it back to iOS 18 — or you want to support both deployment targets from the same codebase. This guide is a five-step recipe.

## Step 1 — Swap the import (one line per file)

```diff
- import FoundationModels
+ import PrivateFoundationModels
+ #if canImport(FoundationModels)
+ import FoundationModels   // keep available for any escape-hatch checks
+ #endif
```

The PFM module reuses the same type names — `LanguageModelSession`, `Instructions`, `Tool`, `Generable`, `Response`, `ResponseStream`, `Transcript`, `GenerationOptions`, `SystemLanguageModel`. You won't get import-clash errors if you don't have both imported in the same file. Apple's framework is conditionally imported above only for code paths that want to interrogate the native framework directly (for example, reading `FoundationModels.SystemLanguageModel.default.availability` raw, instead of through PFM's translation).

## Step 2 — Install a backend at app startup

This is the only structural addition. Apple's framework auto-discovers the on-device model; PFM needs to be told which runtime to use.

```swift
import PrivateFoundationModels
import PrivateFoundationModelsApple
import PrivateFoundationModelsCoreML

@MainActor
func bootstrapLanguageModel() async throws {
    if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *),
       AppleFoundationModel.isAvailable {
        // iOS 26+: route to Apple's native model exactly as if the
        // `import FoundationModels` was still pointing at Apple.
        SystemLanguageModel.default = SystemLanguageModel(
            backend: AppleFoundationModel.load()
        )
    } else {
        // iOS 18+ fallback. Pick whichever CoreML catalog model you
        // shipped; this one is the smallest.
        SystemLanguageModel.default = SystemLanguageModel(
            backend: try await CoreMLLanguageModel.load(.lfm2_5_350M)
        )
    }
}
```

Call `bootstrapLanguageModel()` once before the first session. Subsequent `LanguageModelSession(...)` initializers will inherit `SystemLanguageModel.default`.

## Step 3 — Everything else compiles unchanged

The following call shapes are byte-identical:

```swift
let session = LanguageModelSession(instructions: Instructions("Be brief."))

let r1 = try await session.respond(to: "Hello.")
let r2 = try await session.respond(to: "And in French?")

for try await snapshot in session.streamResponse(to: "A haiku.") {
    print(snapshot.content)
}

@Generable
struct Profile {
    @Guide(description: "Person's name") let name: String
    let age: Int
}

let profile = try await session.respond(
    to: "Invent a person.",
    generating: Profile.self
)

struct Lookup: Tool {
    struct Arguments: Generable {
        let city: String
        static var generationSchema: GenerationSchema {
            GenerationSchema(type: "object",
                              properties: ["city": .init(type: "string")],
                              required: ["city"])
        }
    }
    let name = "lookup"
    let description = "Looks up a city."
    func call(arguments: Arguments) async throws -> String { "Tokyo, 22°C" }
}

let toolSession = LanguageModelSession(
    tools: [Lookup()],
    instructions: Instructions("Use the lookup tool when needed.")
)
let answer = try await toolSession.respond(to: "How's Tokyo?")
```

If something doesn't compile against PFM that compiles against Apple's framework, [open an issue](https://github.com/john-rocky/PrivateFoundationModels/issues/new) — the goal is byte-compatibility.

## Step 4 — Be aware of these (small) behavior differences

These are not failures; they're differences that surface in subtle places.

| Aspect | Apple FM (native) | PFM Apple backend | PFM CoreML / MLX |
|---|---|---|---|
| `prewarm(promptPrefix:)` | Builds adapter cache for the prefix | No-op (per-call session) | Triggers backend's prewarm hook |
| Tool calling | Runs internally | Runs internally; PFM reconstructs transcript turns | PFM drives the loop turn-by-turn |
| `Generable.PartiallyGenerated` | Apple's macro-derived partial type | PFM emits JSON snapshots that parse incrementally | Same |
| Refusal explanation | `GenerationError.refusal.explanation` returns Apple's elaboration | Not yet translated to PFM | Backend dependent |
| Safety guardrails | Apple's | Apple's (passthrough) | None (backend dependent) |
| Schema enforcement | Apple's constrained sampler | Apple's constrained sampler (via PFM schema translation) | Prompt-based, no constrained sampler |

The most user-visible delta is the last one: on the Apple backend `respond(to:generating:)` is **mathematically guaranteed** to produce valid JSON of your type (Apple's sampler does the work). On CoreML / MLX the model is asked to produce JSON via prompt; small models can occasionally emit invalid JSON, which surfaces as `GenerationError.decodingFailure`. Pick the backend that matches your tolerance.

## Step 5 — Drop PFM when you're ready

When your deployment target lifts above iOS 26 / macOS 26 / visionOS 26 and you stop wanting the bring-your-own-model story, the path back to Apple's framework is mechanical:

```bash
# Replace the import.
git ls-files '*.swift' | xargs sed -i '' 's/PrivateFoundationModels/FoundationModels/g'

# Drop the bootstrap call.
# (Apple's framework doesn't need it.)

# Remove the package dependency from Package.swift.
```

Everything else — your `@Generable` types, your `Tool` instances, your `LanguageModelSession` call sites — keeps compiling, because they always matched Apple's shape.

## Step 6 — Or stay on PFM

The longer your code runs through PFM, the easier it is to:

- Run on iOS 18 / iOS 17 / macOS 14 alongside iOS 26 from the same call site.
- Swap to a domain-tuned CoreML model (your fine-tuned Gemma 4 E2B, your custom-converted Qwen3.5) without re-architecting prompt code.
- Run on MLX for desktop research / prototyping and CoreML for shipping iPhone builds, using identical call sites.

Either way the call site is yours. PFM stays out of the way of your domain code.

---

Questions? [Open an issue](https://github.com/john-rocky/PrivateFoundationModels/issues/new) or jump straight to a PR.
