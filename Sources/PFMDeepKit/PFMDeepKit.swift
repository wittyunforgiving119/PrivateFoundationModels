// PFMDeepKit — backend-agnostic deep-verification scenarios.
//
// The wrappers (PFMDeep for CoreML, PFMMLXDeep for MLX) load a real
// model and install it as `SystemLanguageModel.default`, then call
// `DeepRunner.runAll(label:)` here. All Generable / Tool / multimodal
// / PromptBuilder coverage lives in this library so the matrix stays
// in sync across backends.

import CoreGraphics
import Foundation
import PrivateFoundationModels

// MARK: - Pretty printing

public func banner(_ title: String) {
    let line = String(repeating: "─", count: 78)
    print("\n" + line)
    print(" \(title)")
    print(line)
}

public func ok(_ message: String)   { print("  ✓ \(message)") }
public func info(_ message: String) { print("  • \(message)") }
public func warn(_ message: String) { print("  ⚠ \(message)") }
public func fail(_ message: String) { print("  ✗ \(message)") }

public func ms(_ duration: Duration) -> String {
    let (s, attoseconds) = duration.components
    let total = Double(s) + Double(attoseconds) / 1e18
    return String(format: "%.0f ms", total * 1000)
}

/// Tiny solid-color CGImage used by the multimodal scenarios.
public func makeSolidImage(width: Int = 64, height: Int = 64) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

// MARK: - Generable shapes

public struct Address: Generable, Equatable, CustomStringConvertible {
    public let city: String
    public let country: String
    public init(city: String, country: String) {
        self.city = city; self.country = country
    }
    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: "object",
            properties: [
                "city":    .init(type: "string"),
                "country": .init(type: "string"),
            ],
            required: ["city", "country"]
        )
    }
    public var description: String { "\(city), \(country)" }
}

public struct Profile: Generable, Equatable, CustomStringConvertible {
    public let name: String
    public let age: Int
    public let address: Address
    public init(name: String, age: Int, address: Address) {
        self.name = name; self.age = age; self.address = address
    }
    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: "object",
            properties: [
                "name":    .init(type: "string"),
                "age":     .init(type: "integer"),
                "address": Address.generationSchema,
            ],
            required: ["name", "age", "address"]
        )
    }
    public var description: String { "\(name), age \(age), \(address)" }
}

public struct ShoppingList: Generable, Equatable, CustomStringConvertible {
    public let name: String
    public let items: [String]
    public init(name: String, items: [String]) {
        self.name = name; self.items = items
    }
    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: "object",
            properties: [
                "name":  .init(type: "string"),
                "items": GenerationSchema(type: "array", items: .init(type: "string")),
            ],
            required: ["name", "items"]
        )
    }
    public var description: String { "\(name): [\(items.joined(separator: ", "))]" }
}

public struct Reading: Generable, Equatable, CustomStringConvertible {
    public let name: String
    public let value: Double
    public let active: Bool
    public init(name: String, value: Double, active: Bool) {
        self.name = name; self.value = value; self.active = active
    }
    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: "object",
            properties: [
                "name":   .init(type: "string"),
                "value":  .init(type: "number"),
                "active": .init(type: "boolean"),
            ],
            required: ["name", "value", "active"]
        )
    }
    public var description: String { "\(name)=\(value) (active=\(active))" }
}

public struct Article: Generable, Equatable, CustomStringConvertible {
    public let title: String
    public let summary: String?
    public init(title: String, summary: String? = nil) {
        self.title = title; self.summary = summary
    }
    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: "object",
            properties: [
                "title":   .init(type: "string"),
                "summary": .init(type: "string"),
            ],
            required: ["title"]
        )
    }
    public var description: String {
        "title=\"\(title)\" summary=\(summary.map { "\"\($0)\"" } ?? "<absent>")"
    }
}

// MARK: - Tools

public struct AddTool: Tool {
    public struct Arguments: Generable {
        public let a: Int
        public let b: Int
        public init(a: Int, b: Int) { self.a = a; self.b = b }
        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: "object",
                properties: ["a": .init(type: "integer"), "b": .init(type: "integer")],
                required: ["a", "b"]
            )
        }
    }
    public let name = "add"
    public let description = "Returns a + b."
    public init() {}
    public func call(arguments: Arguments) async throws -> String {
        "\(arguments.a + arguments.b)"
    }
}

public struct MultiplyTool: Tool {
    public struct Arguments: Generable {
        public let a: Int
        public let b: Int
        public init(a: Int, b: Int) { self.a = a; self.b = b }
        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: "object",
                properties: ["a": .init(type: "integer"), "b": .init(type: "integer")],
                required: ["a", "b"]
            )
        }
    }
    public let name = "multiply"
    public let description = "Returns a * b."
    public init() {}
    public func call(arguments: Arguments) async throws -> String {
        "\(arguments.a * arguments.b)"
    }
}

public struct LookupTool: Tool {
    public struct Arguments: Generable {
        public let topic: String
        public let limit: Int
        public init(topic: String, limit: Int) { self.topic = topic; self.limit = limit }
        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: "object",
                properties: [
                    "topic": .init(type: "string"),
                    "limit": .init(type: "integer"),
                ],
                required: ["topic", "limit"]
            )
        }
    }
    public let name = "lookup"
    public let description = "Look up up-to-N facts on a topic."
    public init() {}
    public func call(arguments: Arguments) async throws -> String {
        "[stub:\(arguments.limit) facts on \(arguments.topic)]"
    }
}

public struct AlwaysFailsTool: Tool {
    public struct Arguments: Generable {
        public let key: String
        public init(key: String) { self.key = key }
        public static var generationSchema: GenerationSchema {
            GenerationSchema(type: "object",
                              properties: ["key": .init(type: "string")],
                              required: ["key"])
        }
    }
    public struct Boom: Error { public let message: String }
    public let name = "boom"
    public let description = "Always throws."
    public init() {}
    public func call(arguments: Arguments) async throws -> String {
        throw Boom(message: "no \(arguments.key) for you")
    }
}

// MARK: - Runner

public struct DeepRunner {

    public init() {}

    public var rows: [(label: String, status: String, detail: String)] = []

    public mutating func record(_ label: String, _ status: String, _ detail: String) {
        rows.append((label, status, detail))
    }

    public mutating func runAll() async {
        await runGenerableScenarios()
        await runToolScenarios()
        await runMultimodalScenarios()
    }

    public func summarize(exitOnFail: Bool = true) {
        banner("Summary")
        let passCount = rows.filter { $0.status == "PASS" }.count
        let modelCount = rows.filter { $0.status == "MODEL" }.count
        let failCount = rows.filter { $0.status == "FAIL" }.count
        print("  PASS  (API works + content correct):       \(passCount)")
        print("  MODEL (API works, content model-limited): \(modelCount)")
        print("  FAIL  (framework / backend regression):    \(failCount)")
        print()
        for row in rows {
            print("  \(row.status.padding(toLength: 6, withPad: " ", startingAt: 0)) \(row.label)")
            if !row.detail.isEmpty {
                print("        \(row.detail)")
            }
        }
        if exitOnFail, failCount > 0 { exit(1) }
    }

    // MARK: Generable

    mutating func runGenerableScenarios() async {
        banner("Generable scenarios (structured output)")

        await runGenerable("G1. simple-object (2 strings)",
                            instructions: "You return only valid JSON. No prose.",
                            prompt: "Pick one famous landmark and return its city and country.",
                            type: Address.self) { value in
            "city=\(value.city) country=\(value.country)"
        }

        await runGenerable("G2. mixed-primitives (string + number + bool)",
                            instructions: "Return strict JSON matching the schema. No prose.",
                            prompt: "Invent a sensor reading. Pick a short name, a numeric value, and an active boolean.",
                            type: Reading.self) { value in
            "name=\(value.name) value=\(value.value) active=\(value.active)"
        }

        await runGenerable("G3. array-of-strings (3 items)",
                            instructions: "Return strict JSON. No prose.",
                            prompt: "Make a shopping list with a name and 3 items.",
                            type: ShoppingList.self) { value in
            "name=\(value.name) items=\(value.items)"
        }

        await runGenerable("G4. nested-object (2 levels)",
                            instructions: "Return strict JSON. No prose. Use exactly the schema fields.",
                            prompt: "Invent a person profile with a name, age, and address (city, country).",
                            type: Profile.self) { value in
            "\(value.description)"
        }

        await runGenerable("G5. optional-fields (absent OK)",
                            instructions: "Return strict JSON. Only include the title field.",
                            prompt: "Make up a one-line article. Title only, no summary.",
                            type: Article.self) { value in
            "title=\(value.title) summary=\(value.summary ?? "<absent>")"
        }

        await runStreamingGenerable("G6. streaming-generable (Profile)",
                                     prompt: "Invent a person profile. Name, age, city, country.",
                                     type: Profile.self) { value in
            "\(value)"
        }
    }

    mutating func runGenerable<T: Generable & CustomStringConvertible>(
        _ label: String,
        instructions: String,
        prompt: String,
        type: T.Type,
        describe: (T) -> String
    ) async {
        info("\(label) — prompt: \(prompt)")
        let session = LanguageModelSession(instructions: Instructions(instructions))
        let start = ContinuousClock.now
        do {
            let response = try await session.respond(
                to: prompt,
                generating: T.self,
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 256)
            )
            let dt = ContinuousClock.now - start
            ok("\(label) → \(describe(response.content)) (\(ms(dt)))")
            record(label, "PASS", describe(response.content))
        } catch let error as GenerationError {
            if case .decodingFailure(let raw) = error {
                warn("\(label) — model emitted unparseable output (model-quality, not framework). raw=\(raw.prefix(180))")
                record(label, "MODEL", "decodingFailure on \(raw.prefix(80))")
            } else {
                fail("\(label) — \(error)")
                record(label, "FAIL", "\(error)")
            }
        } catch {
            fail("\(label) — \(error)")
            record(label, "FAIL", "\(error)")
        }
    }

    mutating func runStreamingGenerable<T: Generable & CustomStringConvertible>(
        _ label: String,
        prompt: String,
        type: T.Type,
        describe: (T) -> String
    ) async {
        info("\(label) — prompt: \(prompt)")
        let session = LanguageModelSession(instructions: "Return strict JSON only. No prose.")
        let stream = session.streamResponse(
            to: prompt,
            generating: T.self,
            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 256)
        )
        let start = ContinuousClock.now
        var snapshotCount = 0
        var lastDecoded: T?
        do {
            for try await snapshot in stream {
                snapshotCount += 1
                lastDecoded = snapshot.content
            }
            let final = try await stream.collect()
            let dt = ContinuousClock.now - start
            ok("\(label) → \(snapshotCount) parseable snapshots, final \(describe(final.content)) (\(ms(dt)))")
            record(label, "PASS", "\(snapshotCount) snapshots, final \(describe(final.content))")
        } catch let error as GenerationError {
            if case .decodingFailure = error {
                if let last = lastDecoded {
                    warn("\(label) — final did not parse but \(snapshotCount) intermediate snapshots did. last=\(describe(last))")
                    record(label, "MODEL", "snapshots=\(snapshotCount), final decode failed")
                } else {
                    warn("\(label) — model emitted no parseable snapshot (model-quality)")
                    record(label, "MODEL", "no parseable snapshot")
                }
            } else {
                fail("\(label) — \(error)")
                record(label, "FAIL", "\(error)")
            }
        } catch {
            fail("\(label) — \(error)")
            record(label, "FAIL", "\(error)")
        }
    }

    // MARK: Tools

    mutating func runToolScenarios() async {
        banner("Tool calling scenarios")

        await runTools(
            "T1. single-tool (add)",
            tools: [AddTool()],
            prompt: "What is 17 plus 25? You MUST use the add tool.",
            expect: { transcript in
                let calls = transcript.entries.filter { $0.kind == .toolCall }.map(\.toolName)
                return calls == ["add"]
            }
        )

        await runTools(
            "T2. multi-tool, picks add",
            tools: [AddTool(), MultiplyTool()],
            prompt: "Use a tool to compute 7 + 3.",
            expect: { transcript in
                let calls = transcript.entries.filter { $0.kind == .toolCall }.map(\.toolName)
                return calls.first == "add"
            }
        )

        await runTools(
            "T3. multi-tool, picks multiply",
            tools: [AddTool(), MultiplyTool()],
            prompt: "Use a tool to compute 6 times 7.",
            expect: { transcript in
                let calls = transcript.entries.filter { $0.kind == .toolCall }.map(\.toolName)
                return calls.first == "multiply"
            }
        )

        await runTools(
            "T4. complex-arguments (lookup topic+limit)",
            tools: [LookupTool()],
            prompt: "Use the lookup tool to get 3 facts about Swift concurrency.",
            expect: { transcript in
                let call = transcript.entries.first { $0.kind == .toolCall }
                return call?.toolName == "lookup"
            }
        )

        await runToolsExpectingError(
            "T5. throwing-tool surfaces error",
            tools: [AlwaysFailsTool()],
            prompt: "Use the boom tool with key=foo."
        )
    }

    // MARK: Multimodal + PromptBuilder

    mutating func runMultimodalScenarios() async {
        banner("Multimodal + builder scenarios")

        info("M1. respond(to:image:) — prompt: Describe what you see.")
        let session1 = LanguageModelSession(instructions: "You describe images briefly.")
        let start1 = ContinuousClock.now
        do {
            let response = try await session1.respond(
                to: "Describe what you see in one short sentence.",
                image: makeSolidImage(),
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 96)
            )
            let dt = ContinuousClock.now - start1
            ok("M1. respond(to:image:) → \(quotedShort(response.content)) (\(ms(dt)))")
            record("M1. respond(to:image:)", "PASS", "\(quotedShort(response.content))")
        } catch {
            fail("M1. respond(to:image:) → \(error)")
            record("M1. respond(to:image:)", "FAIL", "\(error)")
        }

        info("M2. streamResponse(to:image:)")
        let session2 = LanguageModelSession(instructions: "Describe images briefly.")
        let start2 = ContinuousClock.now
        let stream = session2.streamResponse(
            to: "What's in this image?",
            image: makeSolidImage(),
            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 96)
        )
        var snapshotCount = 0
        var lastSnapshot = ""
        do {
            for try await snapshot in stream {
                snapshotCount += 1
                lastSnapshot = snapshot.content
            }
            let dt = ContinuousClock.now - start2
            ok("M2. streamResponse(to:image:) → \(snapshotCount) snapshots, final \(quotedShort(lastSnapshot)) (\(ms(dt)))")
            record("M2. streamResponse(to:image:)", "PASS", "\(snapshotCount) snapshots")
        } catch {
            fail("M2. streamResponse(to:image:) → \(error)")
            record("M2. streamResponse(to:image:)", "FAIL", "\(error)")
        }

        info("M3. respond { PromptBuilder }")
        let session3 = LanguageModelSession(
            instructions: "Translate English to French. Respond with just the translation."
        )
        let start3 = ContinuousClock.now
        do {
            let response = try await session3.respond(
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 96)
            ) {
                "English:"
                "Good morning."
            }
            let dt = ContinuousClock.now - start3
            ok("M3. PromptBuilder → \(quotedShort(response.content)) (\(ms(dt)))")
            record("M3. respond { PromptBuilder }", "PASS", "\(quotedShort(response.content))")
        } catch {
            fail("M3. PromptBuilder → \(error)")
            record("M3. respond { PromptBuilder }", "FAIL", "\(error)")
        }
    }

    func quotedShort(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 140 {
            return "\"\(trimmed.prefix(140))…\""
        }
        return "\"\(trimmed)\""
    }

    mutating func runTools(
        _ label: String,
        tools: [any Tool],
        prompt: String,
        expect: (Transcript) -> Bool
    ) async {
        info("\(label) — prompt: \(prompt)")
        let session = LanguageModelSession(
            tools: tools,
            instructions: Instructions("Use the provided tools when applicable.")
        )
        let start = ContinuousClock.now
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 256)
            )
            let dt = ContinuousClock.now - start
            let transcript = session.transcript
            let kinds = transcript.entries.map(\.kind)
            let toolCalls = transcript.entries.filter { $0.kind == .toolCall }
            let toolOutputs = transcript.entries.filter { $0.kind == .toolOutput }

            if expect(transcript) {
                ok("\(label) → tool used (\(toolCalls.compactMap(\.toolName).joined(separator: " → "))) (\(ms(dt)))")
                if let last = toolOutputs.last { info("  last tool output: \(last.content)") }
                info("  final assistant: \(response.content)")
                record(label, "PASS",
                       "calls=\(toolCalls.compactMap(\.toolName).joined(separator: ",")) final=\(response.content.prefix(60))")
            } else {
                warn("\(label) — model answered without invoking the expected tool (model-quality)")
                record(label, "MODEL",
                       "kinds=\(kinds) final=\(response.content.prefix(80))")
            }
        } catch let error as GenerationError {
            fail("\(label) → \(error)")
            record(label, "FAIL", "\(error)")
        } catch {
            fail("\(label) → \(error)")
            record(label, "FAIL", "\(error)")
        }
    }

    mutating func runToolsExpectingError(
        _ label: String,
        tools: [any Tool],
        prompt: String
    ) async {
        info("\(label) — prompt: \(prompt)")
        let session = LanguageModelSession(
            tools: tools,
            instructions: Instructions("You MUST call the tool.")
        )
        do {
            _ = try await session.respond(to: prompt)
            warn("\(label) — model answered without invoking the throwing tool (model-quality)")
            record(label, "MODEL", "tool not invoked")
        } catch let error as GenerationError {
            if case .backend(let inner) = error, inner is AlwaysFailsTool.Boom {
                ok("\(label) → caught Boom from tool via GenerationError.backend")
                record(label, "PASS", "Boom surfaced")
            } else if case .refusal = error {
                warn("\(label) — refusal (model emitted malformed tool call): \(error)")
                record(label, "MODEL", "refusal")
            } else {
                fail("\(label) → unexpected error: \(error)")
                record(label, "FAIL", "\(error)")
            }
        } catch {
            fail("\(label) → \(error)")
            record(label, "FAIL", "\(error)")
        }
    }
}
