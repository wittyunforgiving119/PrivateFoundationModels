# PFMSwitcher — Apple FoundationModels ↔ CoreML model switcher

A minimal SwiftUI iOS app that lets you flip between **Apple's `FoundationModels`** framework (iOS 26+) and any model the **`PrivateFoundationModelsCoreML`** backend can load — using exactly the same `LanguageModelSession.respond(...)` call site.

The app exists to make one point concrete: every call site is identical. A picker change replaces the resident backend; the chat code never knows the difference.

## What this proves

| | Same code, two backends |
|---|---|
| `LanguageModelSession(instructions:)` | ✅ |
| `session.streamResponse(to:)` | ✅ |
| Cumulative `Snapshot.content` semantics | ✅ |
| `Transcript`, `GenerationOptions` | ✅ |
| Switching cost: 1 backend install line, runtime selectable | ✅ |

## Memory contract

On-device LLMs use 0.8 – 5.5 GB of RAM. A naive "switch model" implementation leaks the previous model and crashes the app on the second swap. This app demonstrates the strict release-before-load policy you actually need:

1. **One backend resident at a time.** `ModelManager.switchTo(_:)` first nils out the current `LanguageModelSession`, replaces `SystemLanguageModel.default` with a placeholder, and yields a runtime tick so ARC actually drops the previous `CoreMLLLM` / `MLModel` references.
2. **No silent retainers.** The chat view holds the session through `@ObservedObject` — when the manager swaps it, SwiftUI releases its reference too.
3. **Live RSS readout.** The header samples `mach_task_basic_info.resident_size` once a second so you can confirm with your own eyes that the previous model unloaded *before* the next one starts paging in.
4. **Memory-warning handler.** On `UIApplication.didReceiveMemoryWarningNotification` the manager aggressively releases the active backend so iOS doesn't jetsam the app. The picker shows "Released after memory warning — pick again to reload."
5. **Streaming, not buffering.** Generation goes through `streamResponse(to:)` and binds the current cumulative snapshot to a `@State String`, never building a parallel array of deltas in memory.

A rough RSS profile on an iPhone 17 Pro (4 GB available to apps):

| State | Resident |
|---|---|
| App launch, no model | ~70 MB |
| LFM2.5-350M loaded | ~880 MB |
| Gemma 4 E2B loaded | ~5.2 GB |
| Apple FoundationModels selected | ~80 MB (Apple FM lives in `daemon`-space, doesn't count against you) |

Switch from Gemma 4 E2B to LFM2.5: resident drops to ~80 MB during the placeholder phase, then rises to ~880 MB after the new model warms up. If you don't see the drop, something is retaining the old session.

## Run it

1. Open Xcode 16+, create a fresh **iOS App** project. Deployment target **iOS 18** (the app's chat works on iOS 18+; the Apple FM selector also requires iOS 26 at runtime).
2. Replace the generated `App` / `ContentView` files with the four files in [`PFMSwitcher/`](PFMSwitcher/):
   - `PFMSwitcherApp.swift`
   - `ModelManager.swift`
   - `ChatView.swift`
   - `AppleFMBridgeBackend.swift`
3. **Package Dependencies → Add Package**: `https://github.com/john-rocky/PrivateFoundationModels` and add both products to the app target:
   - `PrivateFoundationModels`
   - `PrivateFoundationModelsCoreML`
4. Build to a real device. First time you pick **LFM2.5-350M** the app downloads ~810 MB to `~/Library/Application Support/PrivateFoundationModels/lfm2.5-350m-coreml/`. Wi-Fi recommended.
5. To enable the **Apple FoundationModels** option, link Apple's framework: in your target's **Frameworks, Libraries, and Embedded Content**, hit `+` and add `FoundationModels.framework` (visible on iOS 26+ SDK toolchains). The bridge file is `#if canImport(FoundationModels)`-gated, so the app still builds and runs on iOS 18 if you skip this step — the picker will throw `appleFMUnavailable` for the Apple option but Wikipedia LFM2.5 / Gemma 4 still works.

## File map

| File | What it does |
|---|---|
| `PFMSwitcherApp.swift` | `@main`, `WindowGroup` |
| `ModelManager.swift` | Selection state, release-before-load logic, RSS sampling, low-memory handling |
| `ChatView.swift` | SwiftUI chat surface — picker / status / memory row / message list / streaming input |
| `AppleFMBridgeBackend.swift` | Implements `LanguageModelBackend` against Apple's `FoundationModels.LanguageModelSession` so the app's chat code keeps calling `PrivateFoundationModels.LanguageModelSession.respond(...)` regardless of which side is active |

## Pattern to copy into your own app

```swift
@MainActor
final class ModelManager: ObservableObject {
    @Published var session: LanguageModelSession?

    func switchTo(_ kind: BackendKind) async throws {
        // 1. Drop the current session FIRST.
        session = nil
        SystemLanguageModel.default = SystemLanguageModel(backend: PlaceholderBackend())
        await Task.yield()                                // let ARC actually free

        // 2. Then load the new one.
        let backend = try await load(kind)
        SystemLanguageModel.default = SystemLanguageModel(backend: backend)
        session = LanguageModelSession(instructions: "…")
    }
}
```

That ordering (release first, then load) is the entire memory contract.
