import Foundation
import Testing
@testable import PrivateFoundationModels

@Suite("JSONExtraction.extractPartialObject")
struct PartialJSONParserTests {

    // MARK: - Already complete objects pass through

    @Test func completeObjectReturnedAsIs() {
        let input = #"{"name":"Alice","age":34}"#
        #expect(JSONExtraction.extractPartialObject(input) == input)
    }

    @Test func completeObjectWithFenceStripped() {
        let input = "```json\n{\"a\":1}\n```"
        #expect(JSONExtraction.extractPartialObject(input) == #"{"a":1}"#)
    }

    @Test func emptyInputReturnsNil() {
        #expect(JSONExtraction.extractPartialObject("") == nil)
    }

    @Test func noOpeningBraceReturnsNil() {
        #expect(JSONExtraction.extractPartialObject("hello world") == nil)
    }

    // MARK: - Partial truncations

    @Test func truncateAfterCompleteStringValue() {
        let input = #"{"name":"Alice","age":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"name":"Alice"}"#)
    }

    @Test func truncateAfterCompleteNumberValue() {
        let input = #"{"a":1.5,"b":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"a":1.5}"#)
    }

    @Test func truncateOnPartialStringValue() {
        // After `"name":"Alice",` we have a safe point. Then `"age":"Bo`
        // starts an incomplete string value — we DON'T mark a new safe
        // point until that string closes. Result: same as the previous
        // safe point.
        let input = #"{"name":"Alice","age":"Bo"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"name":"Alice"}"#)
    }

    @Test func truncateAfterTrueLiteral() {
        let input = #"{"active":true,"name":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"active":true}"#)
    }

    @Test func truncateAfterFalseLiteral() {
        let input = #"{"active":false,"name":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"active":false}"#)
    }

    @Test func truncateAfterNullLiteral() {
        let input = #"{"data":null,"name":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"data":null}"#)
    }

    // MARK: - Nested

    @Test func truncateAfterClosedSubObject() {
        let input = #"{"nested":{"x":1},"more":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"nested":{"x":1}}"#)
    }

    @Test func truncateAfterClosedArray() {
        let input = #"{"items":[1,2,3],"next":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"items":[1,2,3]}"#)
    }

    @Test func nestedPartialAddsClosers() {
        // Inside the inner object, "x":1 just completed; the inner object
        // and the outer object both need closing braces.
        let input = #"{"nested":{"x":1,"y":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"nested":{"x":1}}"#)
    }

    @Test func nestedArrayPartialAddsClosers() {
        let input = #"{"items":[1,2,"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"items":[1,2]}"#)
    }

    // MARK: - No safe point yet

    @Test func keyWithoutValueReturnsNil() {
        let input = #"{"name":"#
        #expect(JSONExtraction.extractPartialObject(input) == nil)
    }

    @Test func openBraceOnlyReturnsNil() {
        #expect(JSONExtraction.extractPartialObject("{") == nil)
    }

    // MARK: - Escapes inside strings

    @Test func escapedQuoteInsideStringIsNotEndOfString() {
        let input = #"{"msg":"hi \"there\"","next":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"msg":"hi \"there\""}"#)
    }

    @Test func braceInsideStringIsNotStructural() {
        let input = #"{"msg":"a { b","next":"#
        #expect(JSONExtraction.extractPartialObject(input) == #"{"msg":"a { b"}"#)
    }

    // MARK: - Streaming decoder integration

    /// Apple's `streamResponse(to:generating:)` emits a `Snapshot<T>` as
    /// soon as the parsed prefix yields a value of `T`. Our previous
    /// implementation only emitted on full-object completion; this test
    /// locks in the new incremental behavior via the stub backend.
    struct PartialReport: Generable, Equatable {
        let title: String
        let summary: String?
        let confidence: Double?

        static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: "object",
                properties: [
                    "title":      .init(type: "string"),
                    "summary":    .init(type: "string"),
                    "confidence": .init(type: "number"),
                ],
                required: ["title"]
            )
        }
    }

    @Test func streamingGenerableEmitsIncrementalSnapshots() async throws {
        let stub = StubBackend()
        // Three deltas. The stub accumulates them: after chunk 1 the
        // buffer is `{"title":"Hello`, then `{"title":"Hello","summary":
        // "world`, then the complete object.
        stub.enqueue(.init(chunks: [
            #"{"title":"Hello"#,
            #"","summary":"world"#,
            #"","confidence":0.95}"#,
        ]))

        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)
        let stream = session.streamResponse(to: "x", generating: PartialReport.self)

        var snapshots: [PartialReport] = []
        for try await snapshot in stream {
            snapshots.append(snapshot.content)
        }

        // At least two emissions: one after `"Hello"` closes (title only,
        // optionals nil), one at the final complete object.
        #expect(snapshots.count >= 2)
        #expect(snapshots.last == PartialReport(title: "Hello", summary: "world", confidence: 0.95))
        #expect(snapshots.first?.title == "Hello")
        #expect(snapshots.first?.summary == nil)
        #expect(snapshots.first?.confidence == nil)
        // Middle snapshot should have title + summary, no confidence yet.
        if snapshots.count >= 3 {
            #expect(snapshots[1].title == "Hello")
            #expect(snapshots[1].summary == "world")
            #expect(snapshots[1].confidence == nil)
        }
    }
}
