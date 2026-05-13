// Apple FoundationModels passthrough backend.
//
// On iOS 26 / macOS 26 / visionOS 26 and newer, this backend routes
// `LanguageModelSession.respond(...)` calls to Apple's actual
// FoundationModels framework — the same model that powers Apple
// Intelligence rewriting, summarization, smart reply. The same call
// site that runs on a CoreML / MLX model on iOS 18 runs on Apple's
// own on-device LLM here, with zero code changes other than the
// backend install line.
//
// Limitations in v0.4 (the first release of this backend):
// - Plain text + streaming text only.
// - `Generable` (structured output) is rejected with a clear error —
//   our `Generable` and Apple's `Generable` are separate Swift
//   protocols, so a cross-protocol bridge needs macro-time work
//   (planned for v0.5). Use the CoreML or MLX backend if you need
//   structured output today.
// - `Tool` is rejected for the same reason.
// - Vision attachments are silently dropped (Apple FM is text-only
//   in iOS 26).

#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation
import PrivateFoundationModels

#if canImport(FoundationModels)

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum AppleFoundationModel {

    /// Returns a backend wired to `FoundationModels.SystemLanguageModel.default`.
    public static func load() -> AppleFoundationModelBackend {
        AppleFoundationModelBackend(model: FoundationModels.SystemLanguageModel.default)
    }

    /// Mirror of Apple's `SystemLanguageModel.default.availability`,
    /// translated into the PFM type so app code can branch without
    /// importing FoundationModels directly.
    public static var availability: PrivateFoundationModels.SystemLanguageModel.Availability {
        translate(FoundationModels.SystemLanguageModel.default.availability)
    }

    /// `true` when Apple Intelligence is on, the device is eligible,
    /// and the model is loaded. The same check Apple's docs recommend.
    public static var isAvailable: Bool {
        FoundationModels.SystemLanguageModel.default.availability == .available
    }

    static func translate(
        _ apple: FoundationModels.SystemLanguageModel.Availability
    ) -> PrivateFoundationModels.SystemLanguageModel.Availability {
        switch apple {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.modelNotReady)
            }
        @unknown default:
            return .unavailable(.modelNotReady)
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public final class AppleFoundationModelBackend: LanguageModelBackend, @unchecked Sendable {

    public let modelIdentifier = "apple/foundation-model"
    private let appleModel: FoundationModels.SystemLanguageModel

    init(model: FoundationModels.SystemLanguageModel) {
        self.appleModel = model
    }

    public var availability: PrivateFoundationModels.SystemLanguageModel.Availability {
        AppleFoundationModel.translate(appleModel.availability)
    }

    public func prewarm() async {
        // Apple's session offers a prewarm hook but it's tied to a
        // specific instructions/prompt prefix. We construct a fresh
        // session per generate(...) call, so prewarming is a no-op.
    }

    // MARK: - Non-streaming

    public func generate(
        transcript: PrivateFoundationModels.Transcript,
        options: PrivateFoundationModels.GenerationOptions,
        schema: PrivateFoundationModels.GenerationSchema?,
        tools: [PrivateFoundationModels.AnyTool]
    ) async throws -> BackendGeneration {
        try guardUnsupported(schema: schema, tools: tools)
        let prepared = Self.prepare(transcript: transcript)
        let session = FoundationModels.LanguageModelSession(
            model: appleModel,
            transcript: prepared.history
        )
        do {
            let response = try await session.respond(
                to: prepared.lastPrompt,
                options: Self.toAppleOptions(options)
            )
            return BackendGeneration(text: response.content)
        } catch is CancellationError {
            throw GenerationError.cancelled
        } catch {
            throw GenerationError.backend(error)
        }
    }

    // MARK: - Streaming

    public func streamGenerate(
        transcript: PrivateFoundationModels.Transcript,
        options: PrivateFoundationModels.GenerationOptions,
        schema: PrivateFoundationModels.GenerationSchema?,
        tools: [PrivateFoundationModels.AnyTool]
    ) -> AsyncThrowingStream<BackendDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try guardUnsupported(schema: schema, tools: tools)
                    let prepared = Self.prepare(transcript: transcript)
                    let session = FoundationModels.LanguageModelSession(
                        model: appleModel,
                        transcript: prepared.history
                    )
                    let stream = session.streamResponse(
                        to: prepared.lastPrompt,
                        options: Self.toAppleOptions(options)
                    )
                    var lastContent = ""
                    for try await snapshot in stream {
                        // For Content == String, Snapshot.content is a
                        // String (PartiallyGenerated == Self).
                        lastContent = snapshot.content
                        continuation.yield(.text(cumulative: lastContent, complete: false))
                    }
                    continuation.yield(.text(cumulative: lastContent, complete: true))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: GenerationError.cancelled)
                } catch let error as GenerationError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: GenerationError.backend(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func guardUnsupported(
        schema: PrivateFoundationModels.GenerationSchema?,
        tools: [PrivateFoundationModels.AnyTool]
    ) throws {
        if schema != nil {
            throw GenerationError.backend(NSError(
                domain: "PrivateFoundationModelsApple",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "AppleFoundationModelBackend does not cross-translate Generable types in v0.4. Use the CoreML or MLX backend for structured output, or wait for v0.5."]
            ))
        }
        if !tools.isEmpty {
            throw GenerationError.backend(NSError(
                domain: "PrivateFoundationModelsApple",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "AppleFoundationModelBackend does not cross-translate Tool types in v0.4. Use the CoreML or MLX backend for tool calling, or wait for v0.5."]
            ))
        }
    }

    private struct Prepared {
        let history: FoundationModels.Transcript
        let lastPrompt: String
    }

    private static func prepare(
        transcript ours: PrivateFoundationModels.Transcript
    ) -> Prepared {
        // The last `.prompt` entry is what the caller is asking now;
        // everything else (instructions + prior turns) seeds Apple's
        // Transcript so the session has the right context.
        var lastPromptIndex: Int? = nil
        for (i, e) in ours.entries.enumerated().reversed() {
            if e.kind == .prompt { lastPromptIndex = i; break }
        }
        var appleEntries: [FoundationModels.Transcript.Entry] = []
        for (i, entry) in ours.entries.enumerated() {
            if i == lastPromptIndex { continue }
            switch entry.kind {
            case .instructions:
                appleEntries.append(.instructions(.init(
                    segments: [.text(.init(content: entry.content))],
                    toolDefinitions: []
                )))
            case .prompt:
                appleEntries.append(.prompt(.init(
                    segments: [.text(.init(content: entry.content))]
                )))
            case .response:
                appleEntries.append(.response(.init(
                    assetIDs: [],
                    segments: [.text(.init(content: entry.content))]
                )))
            case .toolCall, .toolOutput:
                // v0.4: tools are rejected by guardUnsupported(...) so
                // we shouldn't reach here, but skip defensively.
                continue
            }
        }
        let lastPrompt: String = lastPromptIndex.flatMap { ours.entries[$0].content } ?? ""
        return Prepared(
            history: FoundationModels.Transcript(entries: appleEntries),
            lastPrompt: lastPrompt
        )
    }

    private static func toAppleOptions(
        _ ours: PrivateFoundationModels.GenerationOptions
    ) -> FoundationModels.GenerationOptions {
        FoundationModels.GenerationOptions(
            sampling: ours.sampling.flatMap(Self.translateSampling),
            temperature: ours.temperature,
            maximumResponseTokens: ours.maximumResponseTokens
        )
    }

    /// Translate our `SamplingMode` into Apple's. Apple's
    /// `random(top:seed:)` and `random(probabilityThreshold:seed:)`
    /// are separate factory functions, so a `case .random` with both
    /// parameters set has to pick one — we prefer probabilityThreshold
    /// when it's specified, fall through to top-k otherwise, fall
    /// through to greedy when neither is set.
    private static func translateSampling(
        _ ours: PrivateFoundationModels.SamplingMode
    ) -> FoundationModels.GenerationOptions.SamplingMode {
        switch ours {
        case .greedy:
            return .greedy
        case let .random(top, probabilityThreshold, seed):
            if let p = probabilityThreshold {
                return .random(probabilityThreshold: p, seed: seed)
            }
            if let k = top {
                return .random(top: k, seed: seed)
            }
            return .greedy
        }
    }
}

#endif
