import Foundation
import PrivateFoundationModels
import PrivateFoundationModelsCoreML
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Darwin

/// Source of truth for the active model. Owns the single resident backend
/// + drives switching with a strict release-before-load policy so two
/// CoreML LLMs never occupy memory simultaneously.
///
/// SwiftUI observes:
///   - `selection`: which backend the user picked.
///   - `status`: load progress / failure.
///   - `session`: the current `LanguageModelSession` (resets on every
///      switch so the conversation history lives with the model that
///      actually saw it).
///   - `residentBytes`: live RSS sample for the memory readout.
@MainActor
final class ModelManager: ObservableObject {

    // MARK: - Backend selection

    enum Selection: Hashable, Identifiable, CustomStringConvertible {
        case none
        case appleFM
        case coreML(CoreMLLanguageModel.Catalog)

        var id: String {
            switch self {
            case .none: return "none"
            case .appleFM: return "apple-fm"
            case .coreML(let c): return "coreml-\(c)"
            }
        }

        var description: String {
            switch self {
            case .none: return "No model"
            case .appleFM: return "Apple FoundationModels"
            case .coreML(let c): return coreMLLabel(c)
            }
        }
    }

    enum Status: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    @Published var selection: Selection = .none
    @Published private(set) var status: Status = .idle
    @Published private(set) var session: LanguageModelSession?
    @Published private(set) var residentBytes: UInt64 = 0
    @Published var lastSwitchDuration: TimeInterval?

    /// All catalog choices the picker exposes. Add / remove freely.
    let coreMLOptions: [CoreMLLanguageModel.Catalog] = [
        .lfm2_5_350M,
        .gemma4E2B,
        .gemma4E4B,
    ]

    private var memoryTimer: Timer?
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        startMemorySampling()
        observeMemoryWarning()
    }

    deinit {
        memoryTimer?.invalidate()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    // MARK: - Switching

    /// Switch the resident backend. Strict order:
    ///
    ///   1. Tear down the current session + replace `SystemLanguageModel.default`
    ///      with the placeholder backend. This drops the only strong
    ///      reference an app holds onto the previous `CoreMLLLM` instance,
    ///      so ARC releases the underlying `MLModel` and its ANE-resident
    ///      weights deterministically.
    ///   2. Run `Task.yield()` + a one-tick delay so any in-flight
    ///      release callbacks fire before we start pulling the next set
    ///      of weights into memory.
    ///   3. Load the new backend.
    ///   4. Install it as `SystemLanguageModel.default` and create a fresh
    ///      `LanguageModelSession`.
    func switchTo(_ target: Selection) async {
        guard target != selection || session == nil else { return }
        let startedAt = Date()

        // -- 1. Release previous backend ----------------------------------
        await releaseCurrentBackend()

        if case .none = target {
            selection = .none
            status = .idle
            return
        }

        // -- 2. Hand the runtime a tick to actually free memory -----------
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // -- 3. Load the new backend --------------------------------------
        selection = target
        status = .loading("Preparing…")
        do {
            let backend = try await makeBackend(for: target)
            // -- 4. Install
            SystemLanguageModel.default = SystemLanguageModel(backend: backend)
            let session = LanguageModelSession(instructions: defaultInstructions(for: target))
            session.prewarm(promptPrefix: nil)
            self.session = session
            status = .ready
            lastSwitchDuration = Date().timeIntervalSince(startedAt)
        } catch {
            status = .failed(String(describing: error))
            session = nil
        }
    }

    /// Reset to "no model loaded" — used by the memory-warning path.
    func releaseCurrentBackend() async {
        session = nil
        // Install the placeholder so any straggling reference goes through
        // the standard `.modelNotReady` path instead of dangling.
        SystemLanguageModel.default = SystemLanguageModel(backend: PlaceholderBackend())
        status = .idle
        // Give ARC the autorelease pool turn it needs to actually drop the
        // previously-installed backend.
        await Task.yield()
    }

    // MARK: - Backend factories

    private func makeBackend(for target: Selection) async throws -> any LanguageModelBackend {
        switch target {
        case .none:
            return PlaceholderBackend()
        case .coreML(let catalog):
            return try await CoreMLLanguageModel.load(catalog) { @Sendable [weak self] stage in
                Task { @MainActor in self?.status = .loading(stage) }
            }
        case .appleFM:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return try await AppleFMBridgeBackend.make()
            } else {
                throw SwitchError.appleFMUnavailable("Requires iOS 26 / macOS 26.")
            }
            #else
            throw SwitchError.appleFMUnavailable("This build was not compiled against the FoundationModels SDK.")
            #endif
        }
    }

    private func defaultInstructions(for target: Selection) -> Instructions {
        switch target {
        case .appleFM: return Instructions("You are a helpful, concise assistant running on Apple Intelligence.")
        case .coreML:  return Instructions("You are a helpful, concise assistant running fully on-device.")
        case .none:    return Instructions("")
        }
    }

    enum SwitchError: Error, LocalizedError {
        case appleFMUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .appleFMUnavailable(let reason): return reason
            }
        }
    }

    // MARK: - Memory sampling

    private func startMemorySampling() {
        sampleResident()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleResident() }
        }
    }

    private func sampleResident() {
        residentBytes = Self.currentResidentBytes()
    }

    /// Pull the resident set size out of `mach_task_basic_info`. Returns 0
    /// on failure.
    static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: - Low-memory notification

    private func observeMemoryWarning() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.releaseCurrentBackend()
                self.status = .failed("Released model after a system memory warning. Pick again to reload.")
            }
        }
        #endif
    }
}

// MARK: - Catalog labels

@MainActor
func coreMLLabel(_ catalog: CoreMLLanguageModel.Catalog) -> String {
    switch catalog {
    case .lfm2_5_350M:       return "LFM2.5 350M (~810 MB, fastest)"
    case .gemma4E2B:         return "Gemma 4 E2B (~5.4 GB, multimodal)"
    case .gemma4E4B:         return "Gemma 4 E4B (~5.5 GB)"
    case .qwen3_5_0_8B:      return "Qwen3.5 0.8B (v0.2 — not loadable yet)"
    case .qwen3_5_2B:        return "Qwen3.5 2B (v0.2 — not loadable yet)"
    case .qwen3VL2BStateful: return "Qwen3-VL 2B (v0.2 — not loadable yet)"
    case .custom(let s):     return "Custom: \(s)"
    }
}

// MARK: - Placeholder

/// Used in between switches so `SystemLanguageModel.default` is never
/// retaining a heavyweight backend longer than necessary.
private struct PlaceholderBackend: LanguageModelBackend {
    let modelIdentifier = "placeholder"
    var availability: SystemLanguageModel.Availability { .unavailable(.modelNotReady) }
    func prewarm() async {}
    func generate(transcript: Transcript, options: GenerationOptions, schema: GenerationSchema?, tools: [AnyTool]) async throws -> BackendGeneration {
        throw GenerationError.unavailable(.modelNotReady)
    }
    func streamGenerate(transcript: Transcript, options: GenerationOptions, schema: GenerationSchema?, tools: [AnyTool]) -> AsyncThrowingStream<BackendDelta, Error> {
        AsyncThrowingStream { $0.finish(throwing: GenerationError.unavailable(.modelNotReady)) }
    }
}
