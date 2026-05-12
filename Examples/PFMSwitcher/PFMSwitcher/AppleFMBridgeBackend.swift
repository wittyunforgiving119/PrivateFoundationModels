// Bridge that exposes Apple's `FoundationModels.LanguageModelSession` as a
// `PrivateFoundationModels.LanguageModelBackend`. Compile-time gated by
// `canImport(FoundationModels)`, runtime gated by `iOS 26`. With this
// installed, the rest of the app talks to ONE API
// (`PrivateFoundationModels.LanguageModelSession.respond(...)`) regardless
// of whether the user picked Apple's on-device 3B model or the CoreML
// backend pointed at any catalog model — which is the whole point of the
// drop-in promise.

#if canImport(FoundationModels)
import FoundationModels
import Foundation
import PrivateFoundationModels

@available(iOS 26.0, macOS 26.0, *)
final class AppleFMBridgeBackend: PrivateFoundationModels.LanguageModelBackend, @unchecked Sendable {

    let modelIdentifier = "apple-foundation-models"

    var availability: PrivateFoundationModels.SystemLanguageModel.Availability {
        let appleAvailability = FoundationModels.SystemLanguageModel.default.availability
        switch appleAvailability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .deviceNotEligible:           return .unavailable(.deviceNotEligible)
            case .modelNotReady:               return .unavailable(.modelNotReady)
            @unknown default:                  return .unavailable(.modelNotReady)
            }
        @unknown default:
            return .unavailable(.modelNotReady)
        }
    }

    static func make() async throws -> AppleFMBridgeBackend {
        let backend = AppleFMBridgeBackend()
        guard case .available = backend.availability else {
            throw BridgeError.unavailable(backend.availability)
        }
        return backend
    }

    enum BridgeError: Error, LocalizedError {
        case unavailable(PrivateFoundationModels.SystemLanguageModel.Availability)
        var errorDescription: String? {
            switch self {
            case .unavailable(let a):
                return "Apple FoundationModels is unavailable on this device: \(a)"
            }
        }
    }

    func prewarm() async {
        await MainActor.run {
            let session = FoundationModels.LanguageModelSession()
            session.prewarm()
        }
    }

    func generate(
        transcript: PrivateFoundationModels.Transcript,
        options: PrivateFoundationModels.GenerationOptions,
        schema: PrivateFoundationModels.GenerationSchema?,
        tools: [PrivateFoundationModels.AnyTool]
    ) async throws -> PrivateFoundationModels.BackendGeneration {
        let (instructions, prompt) = render(transcript: transcript)
        let session: FoundationModels.LanguageModelSession
        if let instructions {
            session = FoundationModels.LanguageModelSession(instructions: FoundationModels.Instructions(instructions))
        } else {
            session = FoundationModels.LanguageModelSession()
        }
        let opts = convert(options: options)
        let response = try await session.respond(to: prompt, options: opts)
        return PrivateFoundationModels.BackendGeneration(text: response.content)
    }

    func streamGenerate(
        transcript: PrivateFoundationModels.Transcript,
        options: PrivateFoundationModels.GenerationOptions,
        schema: PrivateFoundationModels.GenerationSchema?,
        tools: [PrivateFoundationModels.AnyTool]
    ) -> AsyncThrowingStream<PrivateFoundationModels.BackendDelta, Error> {
        AsyncThrowingStream { continuation in
            let (instructions, prompt) = render(transcript: transcript)
            let opts = convert(options: options)
            let task = Task {
                let session: FoundationModels.LanguageModelSession
                if let instructions {
                    session = FoundationModels.LanguageModelSession(instructions: FoundationModels.Instructions(instructions))
                } else {
                    session = FoundationModels.LanguageModelSession()
                }
                do {
                    let stream = session.streamResponse(to: prompt, options: opts)
                    var lastSnapshot = ""
                    for try await snapshot in stream {
                        lastSnapshot = snapshot.content
                        continuation.yield(.text(cumulative: snapshot.content, complete: false))
                    }
                    continuation.yield(.text(cumulative: lastSnapshot, complete: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Conversion helpers

    private func render(transcript: PrivateFoundationModels.Transcript)
        -> (instructions: String?, prompt: String)
    {
        var instructions: String?
        var history: [String] = []
        var lastPrompt = ""
        for entry in transcript.entries {
            switch entry.kind {
            case .instructions:
                instructions = entry.content
            case .prompt:
                if !lastPrompt.isEmpty {
                    history.append("User: \(lastPrompt)")
                }
                lastPrompt = entry.content
            case .response:
                history.append("Assistant: \(entry.content)")
            case .toolCall, .toolOutput:
                break
            }
        }
        guard !history.isEmpty else {
            return (instructions, lastPrompt)
        }
        let prefix = history.joined(separator: "\n\n")
        return (instructions, "\(prefix)\n\nUser: \(lastPrompt)")
    }

    private func convert(options: PrivateFoundationModels.GenerationOptions) -> FoundationModels.GenerationOptions {
        FoundationModels.GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maximumResponseTokens
        )
    }
}
#endif
