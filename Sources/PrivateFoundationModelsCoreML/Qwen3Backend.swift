import CoreML
import CoreMLLLM
import Foundation
import PrivateFoundationModels
import Tokenizers

/// `LanguageModelBackend` for the Qwen3.5 family. CoreML-LLM upstream ships
/// Qwen3.5 behind a separate Swift class (`Qwen35MLKVGenerator`) with a
/// different model-folder layout than the unified `CoreMLLLM.load(from:)`
/// path, so the Qwen catalog entries route here instead of through
/// `CoreMLBackendImpl`.
///
/// What this adapter does:
///
/// 1. Drives `Qwen35MLKVGenerator` (the ANE-MLState 4-chunk decoder).
/// 2. Owns a `Tokenizer` loaded from the *source* HuggingFace repo
///    (e.g. `Qwen/Qwen3.5-0.8B`) — the mlboydaisuke CoreML repos don't
///    embed the tokenizer.
/// 3. Translates `Transcript` → `[Int32]` via the chat template, calls
///    `generate(...)`, decodes token IDs back to text per step for the
///    streaming path.
/// 4. Implements the same TOOL_CALL / schema-into-system-prompt convention
///    `CoreMLBackendImpl` uses so the session-level `Tool` / `Generable`
///    pipeline works unchanged.
public final class Qwen3Backend: LanguageModelBackend, @unchecked Sendable {

    public let underlying: Qwen35MLKVGenerator
    public let tokenizer: any Tokenizer
    public let modelIdentifier: String

    private let queue = SerialQueue()

    public var availability: SystemLanguageModel.Availability { .available }

    init(generator: Qwen35MLKVGenerator, tokenizer: any Tokenizer, modelIdentifier: String) {
        self.underlying = generator
        self.tokenizer = tokenizer
        self.modelIdentifier = modelIdentifier
    }

    public func prewarm() async {
        // Qwen35MLKVGenerator.load() already runs a warm-up step.
    }

    public func tokenCount(_ text: String) async -> Int? {
        tokenizer.encode(text: text).count
    }

    // MARK: - generate

    public func generate(
        transcript: Transcript,
        options: GenerationOptions,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) async throws -> BackendGeneration {
        try await queue.run { [self] in
            let inputIds = try buildInputIds(transcript: transcript, schema: schema, tools: tools)
            let temperature = Float(options.temperature ?? 0.7)
            let maxNewTokens = options.maximumResponseTokens ?? 512
            let outputIds: [Int32]
            do {
                outputIds = try await underlying.generate(
                    inputIds: inputIds,
                    maxNewTokens: maxNewTokens,
                    temperature: temperature
                )
            } catch is CancellationError {
                throw GenerationError.cancelled
            } catch {
                throw GenerationError.backend(error)
            }
            let text = decodeTrimmingSpecials(outputIds)
            return Qwen3Backend.parse(raw: text, tools: tools, schema: schema)
        }
    }

    // MARK: - streamGenerate

    public func streamGenerate(
        transcript: Transcript,
        options: GenerationOptions,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) -> AsyncThrowingStream<BackendDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await self.queue.run {
                        let inputIds = try self.buildInputIds(transcript: transcript, schema: schema, tools: tools)
                        let temperature = Float(options.temperature ?? 0.7)
                        let maxNewTokens = options.maximumResponseTokens ?? 512

                        // Use a class wrapper so the @Sendable onToken can mutate state.
                        let buffer = TokenBuffer(tokenizer: self.tokenizer)

                        let _ = try await self.underlying.generate(
                            inputIds: inputIds,
                            maxNewTokens: maxNewTokens,
                            temperature: temperature,
                            onToken: { id in
                                buffer.append(id)
                                let cumulative = buffer.cumulative
                                if buffer.sawToolMarker { return }
                                if cumulative.contains(Qwen3Backend.toolCallMarker) {
                                    buffer.sawToolMarker = true
                                    return
                                }
                                continuation.yield(.text(cumulative: cumulative, complete: false))
                            }
                        )

                        let raw = buffer.cumulative
                        let parsed = Qwen3Backend.parse(raw: raw, tools: tools, schema: schema)
                        if let call = parsed.toolCalls.first {
                            continuation.yield(.tool(call))
                            continuation.finish()
                            return
                        }
                        // Final emission uses the raw cumulative buffer (NOT the
                        // parsed-then-trimmed text) so the cumulative-prefix invariant
                        // on `ResponseStream` holds. Trimming happens at the
                        // session/transcript level.
                        continuation.yield(.text(cumulative: raw, complete: true))
                        continuation.finish()
                    }
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

    // MARK: - Transcript → input ids

    private func buildInputIds(
        transcript: Transcript,
        schema: GenerationSchema?,
        tools: [AnyTool]
    ) throws -> [Int32] {
        // The Qwen3.5 family uses the ChatML template (<|im_start|> / <|im_end|>).
        // We render it manually instead of going through
        // `tokenizer.applyChatTemplate(messages:)` so the call doesn't have
        // to thread `[[String: Any]]` across actor boundaries under Swift 6
        // strict-concurrency (Any does not conform to Sendable).
        struct Message {
            let role: String
            let content: String
        }
        var systemParts: [String] = []
        var messages: [Message] = []

        for entry in transcript.entries {
            switch entry.kind {
            case .instructions:
                systemParts.append(entry.content)
            case .prompt:
                messages.append(Message(role: "user", content: entry.content))
            case .response:
                messages.append(Message(role: "assistant", content: entry.content))
            case .toolCall:
                let body = "\(Qwen3Backend.toolCallMarker) \(entry.toolName ?? "?")\n\(entry.toolArguments ?? "{}")"
                messages.append(Message(role: "assistant", content: body))
            case .toolOutput:
                let body = "[Tool result for \(entry.toolName ?? "?")]\n\(entry.content)"
                messages.append(Message(role: "user", content: body))
            }
        }

        if let schema {
            let json = (try? Qwen3Backend.schemaToJSONString(schema)) ?? "{}"
            systemParts.append(
                "You MUST respond with a single JSON value that conforms to this schema. "
                + "Do not include any prose, code fences, or explanation. Schema:\n\(json)"
            )
        }
        if !tools.isEmpty {
            systemParts.append(Qwen3Backend.toolsSystemPrompt(tools))
        }
        if !systemParts.isEmpty {
            let merged = systemParts.joined(separator: "\n\n")
            messages.insert(Message(role: "system", content: merged), at: 0)
        }

        var prompt = ""
        for message in messages {
            prompt += "<|im_start|>\(message.role)\n\(message.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"

        let ids = tokenizer.encode(text: prompt)
        return ids.map(Int32.init)
    }

    private func decodeTrimmingSpecials(_ ids: [Int32]) -> String {
        // Drop the trailing EOS-family tokens (<|im_end|>, <|endoftext|>) so
        // they don't leak into the assistant's visible output.
        let stops: Set<Int32> = [248044, 248045, 248046]
        let trimmed = ids.prefix(while: { !stops.contains($0) })
        return tokenizer.decode(tokens: trimmed.map(Int.init))
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
        // Reasoning model preamble: Qwen3.5 wraps its scratchpad in
        // `<think>...</think>` before producing the final answer. Strip
        // it first so the downstream JSON / tool-call extraction sees the
        // actual output.
        let dethought = JSONExtraction.stripThinkBlocks(raw)
        let trimmed = dethought.trimmingCharacters(in: .whitespacesAndNewlines)

        if !tools.isEmpty, let range = trimmed.range(of: toolCallMarker) {
            let after = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            // Accept all three layouts produced in the wild:
            //   1. TOOL_CALL: <name>\n<json>
            //   2. TOOL_CALL: <name> <json>
            //   3. TOOL_CALL: <json>            (small model omits name)
            if let braceIndex = after.firstIndex(of: "{") {
                // First whitespace-delimited token before `{` is the tool
                // name; any interior text (extra prose the model added) is
                // discarded.
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

/// Streaming buffer that accumulates decoded tokens. Reference type so the
/// `@Sendable` onToken closure can mutate state without capturing inout.
private final class TokenBuffer: @unchecked Sendable {
    var cumulative: String = ""
    var sawToolMarker: Bool = false
    private let tokenizer: any Tokenizer
    private let stops: Set<Int32> = [248044, 248045, 248046]

    init(tokenizer: any Tokenizer) {
        self.tokenizer = tokenizer
    }

    func append(_ id: Int32) {
        guard !stops.contains(id) else { return }
        let piece = tokenizer.decode(tokens: [Int(id)])
        cumulative += piece
    }
}
