import CoreGraphics
import CoreImage
import Foundation
import MLXLLM
import MLXLMCommon
import PrivateFoundationModels

/// `LanguageModelBackend` for ml-explore/mlx-swift-lm.
///
/// Generation strategy: each `generate(...)` call constructs a fresh
/// `MLXLMCommon.ChatSession` seeded with the transcript history (so prior
/// turns are baked into the model's KV cache once at session start), then
/// `respond(to:)` on the latest user prompt. This keeps state lifetime
/// scoped to a single API call and avoids cross-call entanglement.
///
/// `Generable` / tool use are handled session-side via the same
/// system-prompt injection convention `CoreMLBackendImpl` uses:
/// the schema and tool list go into the rendered `Instructions`, the
/// model emits `TOOL_CALL: name\n{json}`, and the JSON extraction is
/// shared via `JSONExtraction`.
public final class MLXBackend: LanguageModelBackend, @unchecked Sendable {

    public let underlying: ModelContainer
    public let modelIdentifier: String
    public var availability: SystemLanguageModel.Availability { .available }

    init(container: ModelContainer, modelIdentifier: String) {
        self.underlying = container
        self.modelIdentifier = modelIdentifier
    }

    public func prewarm() async {
        // ModelContainer is already warm after loadModelContainer; nothing
        // to do here. A future revision can schedule a 1-token dummy
        // forward pass to spin up Metal pipelines.
    }

    // MARK: - Non-streaming

    public func generate(
        transcript: Transcript,
        options: GenerationOptions,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) async throws -> BackendGeneration {
        try await generate(transcript: transcript, attachments: [],
                            options: options, schema: schema, tools: tools)
    }

    public func generate(
        transcript: Transcript,
        attachments: [BackendAttachment],
        options: GenerationOptions,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) async throws -> BackendGeneration {
        let prepared = Self.prepare(transcript: transcript, schema: schema, tools: tools)
        let session = ChatSession(
            underlying,
            instructions: prepared.instructions,
            history: prepared.history,
            generateParameters: Self.convertOptions(options)
        )
        let images = Self.images(from: attachments)
        let raw: String
        do {
            if let firstImage = images.first {
                // VLM models accept this; for text-only LLM models the
                // image is silently ignored on a retry below.
                do {
                    raw = try await session.respond(
                        to: prepared.lastPrompt, image: firstImage)
                } catch is CancellationError {
                    throw GenerationError.cancelled
                } catch {
                    raw = try await session.respond(to: prepared.lastPrompt)
                }
            } else {
                raw = try await session.respond(to: prepared.lastPrompt)
            }
        } catch is CancellationError {
            throw GenerationError.cancelled
        } catch {
            throw GenerationError.backend(error)
        }
        return Self.parse(raw: raw, tools: tools, schema: schema)
    }

    // MARK: - Streaming

    public func streamGenerate(
        transcript: Transcript,
        options: GenerationOptions,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) -> AsyncThrowingStream<BackendDelta, Error> {
        streamGenerate(transcript: transcript, attachments: [],
                        options: options, schema: schema, tools: tools)
    }

    public func streamGenerate(
        transcript: Transcript,
        attachments: [BackendAttachment],
        options: GenerationOptions,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) -> AsyncThrowingStream<BackendDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let prepared = Self.prepare(transcript: transcript, schema: schema, tools: tools)
                    let session = ChatSession(
                        self.underlying,
                        instructions: prepared.instructions,
                        history: prepared.history,
                        generateParameters: Self.convertOptions(options)
                    )
                    let images = Self.images(from: attachments)
                    // For VLM models we pass the image straight through;
                    // for text-only LLMs MLXLMCommon will treat the
                    // images list as empty since the model doesn't have
                    // an image processor.
                    let upstream: AsyncThrowingStream<String, Error> =
                        session.streamResponse(
                            to: prepared.lastPrompt,
                            images: images.isEmpty ? [] : [images[0]],
                            videos: []
                        )

                    var cumulative = ""
                    var sawToolMarker = false
                    for try await chunk in upstream {
                        cumulative += chunk
                        if !sawToolMarker && cumulative.contains(MLXBackend.toolCallMarker) {
                            sawToolMarker = true
                            continue
                        }
                        if !sawToolMarker {
                            continuation.yield(.text(cumulative: cumulative, complete: false))
                        }
                    }

                    let parsed = MLXBackend.parse(raw: cumulative, tools: tools, schema: schema)
                    if let call = parsed.toolCalls.first {
                        continuation.yield(.tool(call))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.text(cumulative: cumulative, complete: true))
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

    // MARK: - Transcript rendering

    private struct Prepared {
        let instructions: String?
        let history: [Chat.Message]
        let lastPrompt: String
    }

    private static func prepare(
        transcript: Transcript,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) -> Prepared {
        var systemParts: [String] = []
        var history: [Chat.Message] = []
        var lastPrompt = ""

        for entry in transcript.entries {
            switch entry.kind {
            case .instructions:
                systemParts.append(entry.content)
            case .prompt:
                if !lastPrompt.isEmpty {
                    history.append(Chat.Message(role: .user, content: lastPrompt))
                }
                lastPrompt = entry.content
            case .response:
                history.append(Chat.Message(role: .assistant, content: entry.content))
            case .toolCall:
                let body = "\(toolCallMarker) \(entry.toolName ?? "?")\n\(entry.toolArguments ?? "{}")"
                history.append(Chat.Message(role: .assistant, content: body))
            case .toolOutput:
                let body = "[Tool result for \(entry.toolName ?? "?")]\n\(entry.content)"
                history.append(Chat.Message(role: .user, content: body))
            }
        }

        if let schema {
            let json = (try? schemaToJSONString(schema)) ?? "{}"
            systemParts.append(
                "You MUST respond with a single JSON value that conforms to this schema. "
                + "Do not include any prose, code fences, or explanation. Schema:\n\(json)"
            )
        }
        if !tools.isEmpty {
            systemParts.append(toolsSystemPrompt(tools))
        }
        let instructions = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        return Prepared(instructions: instructions, history: history, lastPrompt: lastPrompt)
    }

    private static func images(from attachments: [BackendAttachment]) -> [UserInput.Image] {
        var out: [UserInput.Image] = []
        for attachment in attachments {
            if case .image(let cgImage) = attachment.kind {
                // MLXLMCommon.UserInput.Image only carries CIImage; lift
                // the caller's CGImage with `CIImage(cgImage:)`.
                out.append(UserInput.Image.ciImage(CIImage(cgImage: cgImage)))
            }
        }
        return out
    }

    private static func convertOptions(_ options: GenerationOptions) -> GenerateParameters {
        var params = GenerateParameters()
        if let t = options.temperature { params.temperature = Float(t) }
        if let n = options.maximumResponseTokens { params.maxTokens = n }
        return params
    }

    // MARK: - Tool / schema prompt rendering (mirrors CoreMLBackendImpl)

    static let toolCallMarker = "TOOL_CALL:"

    static func toolsSystemPrompt(_ tools: [AnyTool]) -> String {
        let entries = tools.map { tool -> String in
            let schemaJSON = (try? schemaToJSONString(tool.argumentsSchema)) ?? "{}"
            return """
            - name: \(tool.name)
              description: \(tool.description)
              arguments_schema: \(schemaJSON)
            """
        }.joined(separator: "\n")
        return """
        You have access to the following tools. To call a tool, respond with EXACTLY:

        \(toolCallMarker) <tool_name>
        <single-line JSON arguments object>

        Do not call a tool unless it is required to answer the user. If you can answer directly, do so without invoking a tool.

        Tools:
        \(entries)
        """
    }

    static func schemaToJSONString(_ schema: GenerationSchema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func parse(
        raw: String,
        tools: [AnyTool],
        schema: GenerationSchema?
    ) -> BackendGeneration {
        let dethought = JSONExtraction.stripThinkBlocks(raw)
        let trimmed = dethought.trimmingCharacters(in: .whitespacesAndNewlines)

        if !tools.isEmpty, let range = trimmed.range(of: toolCallMarker) {
            let after = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if let braceIndex = after.firstIndex(of: "{") {
                let namePart = String(after[..<braceIndex])
                    .components(separatedBy: .whitespacesAndNewlines)
                    .first(where: { !$0.isEmpty }) ?? ""
                let jsonPart = String(after[braceIndex...])
                let cleaned = JSONExtraction.extractObject(jsonPart) ?? JSONExtraction.stripCodeFence(jsonPart)
                let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedCleaned.hasPrefix("{") {
                    let resolvedName: String
                    if !namePart.isEmpty {
                        resolvedName = namePart
                    } else if tools.count == 1 {
                        resolvedName = tools[0].name
                    } else {
                        return BackendGeneration(text: trimmed)
                    }
                    return BackendGeneration(text: nil, toolCalls: [
                        .init(name: resolvedName, argumentsJSON: trimmedCleaned)
                    ])
                }
            }
            return BackendGeneration(text: trimmed)
        }
        if schema != nil {
            if let json = JSONExtraction.extractObject(trimmed) {
                return BackendGeneration(text: json)
            }
            return BackendGeneration(text: JSONExtraction.stripCodeFence(trimmed))
        }
        return BackendGeneration(text: trimmed)
    }
}
