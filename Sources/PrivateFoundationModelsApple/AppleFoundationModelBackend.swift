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
// What this backend supports (v0.4.1+):
// - Plain text + streaming text.
// - `Generable` structured output and streaming Generable, including
//   nested objects, arrays, optionals, and primitive mixes — PFM's
//   `GenerationSchema` (JSON-Schema-shaped) is translated into Apple's
//   `GenerationSchema` via `DynamicGenerationSchema`. The decoded
//   `GeneratedContent` is re-serialized to JSON so PFM's existing
//   `Generable` JSON decoder takes over.
//
// What's not supported yet:
// - `Tool` is rejected with a clear error — cross-protocol Tool
//   bridging is queued for v0.5.
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
        try guardUnsupported(tools: tools)
        let prepared = Self.prepare(transcript: transcript)
        let session = FoundationModels.LanguageModelSession(
            model: appleModel,
            transcript: prepared.history
        )
        let appleOptions = Self.toAppleOptions(options)
        do {
            if let pfmSchema = schema {
                let appleSchema = try FoundationModels.GenerationSchema(
                    root: Self.pfmSchemaToDynamic(pfmSchema, name: "Root"),
                    dependencies: []
                )
                let response = try await session.respond(
                    to: prepared.lastPrompt,
                    schema: appleSchema,
                    options: appleOptions
                )
                return BackendGeneration(text: Self.generatedContentToJSON(response.content))
            } else {
                let response = try await session.respond(
                    to: prepared.lastPrompt,
                    options: appleOptions
                )
                return BackendGeneration(text: response.content)
            }
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
                    try guardUnsupported(tools: tools)
                    let prepared = Self.prepare(transcript: transcript)
                    let session = FoundationModels.LanguageModelSession(
                        model: appleModel,
                        transcript: prepared.history
                    )
                    let appleOptions = Self.toAppleOptions(options)

                    if let pfmSchema = schema {
                        let appleSchema = try FoundationModels.GenerationSchema(
                            root: Self.pfmSchemaToDynamic(pfmSchema, name: "Root"),
                            dependencies: []
                        )
                        let stream = session.streamResponse(
                            to: prepared.lastPrompt,
                            schema: appleSchema,
                            options: appleOptions
                        )
                        var lastJSON = "{}"
                        for try await snapshot in stream {
                            // snapshot.content is GeneratedContent
                            // (PartiallyGenerated == Self for Generable).
                            lastJSON = Self.generatedContentToJSON(snapshot.content)
                            continuation.yield(.text(cumulative: lastJSON, complete: false))
                        }
                        continuation.yield(.text(cumulative: lastJSON, complete: true))
                    } else {
                        let stream = session.streamResponse(
                            to: prepared.lastPrompt,
                            options: appleOptions
                        )
                        var lastContent = ""
                        for try await snapshot in stream {
                            lastContent = snapshot.content
                            continuation.yield(.text(cumulative: lastContent, complete: false))
                        }
                        continuation.yield(.text(cumulative: lastContent, complete: true))
                    }
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
        tools: [PrivateFoundationModels.AnyTool]
    ) throws {
        if !tools.isEmpty {
            throw GenerationError.backend(NSError(
                domain: "PrivateFoundationModelsApple",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "AppleFoundationModelBackend does not cross-translate Tool types yet (planned for v0.5). Use the CoreML or MLX backend for tool calling today."]
            ))
        }
    }

    // MARK: - Schema translation

    /// Translate PFM's JSON-Schema-shaped `GenerationSchema` into Apple's
    /// `DynamicGenerationSchema`. The latter is fed to
    /// `FoundationModels.GenerationSchema(root:dependencies:)` so we can
    /// invoke `session.respond(to:schema:)` without our types having to
    /// conform to Apple's `Generable` protocol.
    private static func pfmSchemaToDynamic(
        _ schema: PrivateFoundationModels.GenerationSchema,
        name: String
    ) -> FoundationModels.DynamicGenerationSchema {
        switch schema.type {
        case "object":
            let props = (schema.properties ?? [:]).map { (key, sub) in
                FoundationModels.DynamicGenerationSchema.Property(
                    name: key,
                    description: sub.description,
                    schema: pfmSchemaToDynamic(sub, name: "\(name).\(key)"),
                    isOptional: !(schema.required ?? []).contains(key)
                )
            }
            return FoundationModels.DynamicGenerationSchema(
                name: name,
                description: schema.description,
                properties: props
            )
        case "array":
            let item = schema.items.map { pfmSchemaToDynamic($0.value, name: "\(name).item") }
                ?? FoundationModels.DynamicGenerationSchema(type: String.self)
            return FoundationModels.DynamicGenerationSchema(
                arrayOf: item, minimumElements: nil, maximumElements: nil
            )
        case "string":
            if let choices = schema.enum, !choices.isEmpty {
                return FoundationModels.DynamicGenerationSchema(
                    name: name, description: schema.description, anyOf: choices
                )
            }
            return FoundationModels.DynamicGenerationSchema(type: String.self)
        case "integer":
            return FoundationModels.DynamicGenerationSchema(type: Int.self)
        case "number":
            return FoundationModels.DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return FoundationModels.DynamicGenerationSchema(type: Bool.self)
        default:
            return FoundationModels.DynamicGenerationSchema(type: String.self)
        }
    }

    /// Render an Apple `GeneratedContent` value as a JSON string so PFM's
    /// existing `Generable` decoder can consume it.
    private static func generatedContentToJSON(
        _ content: FoundationModels.GeneratedContent
    ) -> String {
        let any = generatedContentToAny(content)
        if let data = try? JSONSerialization.data(
            withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys]
        ),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    private static func generatedContentToAny(
        _ content: FoundationModels.GeneratedContent
    ) -> Any {
        switch content.kind {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr):
            return arr.map { generatedContentToAny($0) }
        case .structure(let props, let orderedKeys):
            var dict = [String: Any]()
            for k in orderedKeys {
                if let v = props[k] { dict[k] = generatedContentToAny(v) }
            }
            return dict
        @unknown default:
            return NSNull()
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
