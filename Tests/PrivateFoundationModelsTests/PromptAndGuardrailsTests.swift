import Foundation
import Testing
@testable import PrivateFoundationModels

@Suite("Prompt + PromptBuilder + Guardrails")
struct PromptAndGuardrailsTests {

    // MARK: - Prompt construction

    @Test func plainInit() {
        let p = Prompt("hello")
        #expect(p.text == "hello")
    }

    @Test func stringLiteralInit() {
        let p: Prompt = "hi there"
        #expect(p.text == "hi there")
    }

    @Test func description() {
        let p = Prompt("hello")
        #expect("\(p)" == "hello")
    }

    @Test func codableRoundTrip() throws {
        let p = Prompt("hello world")
        let data = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(Prompt.self, from: data)
        #expect(restored == p)
    }

    // MARK: - PromptBuilder

    @Test func builderConcatsStringSegmentsWithDoubleNewline() {
        @PromptBuilder func make() -> Prompt {
            "First"
            "Second"
        }
        #expect(make().text == "First\n\nSecond")
    }

    @Test func builderAcceptsPromptValues() {
        @PromptBuilder func make() -> Prompt {
            Prompt("alpha")
            Prompt("beta")
        }
        #expect(make().text == "alpha\n\nbeta")
    }

    @Test func builderSupportsConditional() {
        @PromptBuilder func make(showHint: Bool) -> Prompt {
            if showHint {
                "with hint"
            } else {
                "no hint"
            }
        }
        #expect(make(showHint: true).text == "with hint")
        #expect(make(showHint: false).text == "no hint")
    }

    // MARK: - Session builder overloads

    @Test func respondBuilderOverloadDeliversConcatenatedPrompt() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(text: "ok"))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        _ = try await session.respond {
            "Translate the following:"
            "Hello world"
        }
        let last = stub.lastTranscript
        let prompt = last?.entries.last(where: { $0.kind == .prompt })?.content ?? ""
        #expect(prompt == "Translate the following:\n\nHello world")
    }

    @Test func streamResponseBuilderOverloadCompiles() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(text: "ok"))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        let stream = session.streamResponse {
            "Compose a haiku"
            "about Swift"
        }
        var snapshots: [String] = []
        for try await snapshot in stream { snapshots.append(snapshot.content) }
        #expect(snapshots.last == "ok")
        let prompt = stub.lastTranscript?.entries.last(where: { $0.kind == .prompt })?.content ?? ""
        #expect(prompt == "Compose a haiku\n\nabout Swift")
    }

    // MARK: - Guardrails

    @Test func guardrailsDefaultExists() {
        let g = Guardrails.default
        let g2 = Guardrails()
        #expect(g == g2)
    }

    @Test func guardrailsAwareInitCompiles() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(text: "ok"))
        let model = SystemLanguageModel(backend: stub)

        // Apple-FM-shaped init: guardrails between model: and tools:.
        let session = LanguageModelSession(
            model: model,
            guardrails: .default,
            tools: [],
            instructions: Instructions("be brief")
        )

        let reply = try await session.respond(to: "hi")
        #expect(reply.content == "ok")
    }
}
