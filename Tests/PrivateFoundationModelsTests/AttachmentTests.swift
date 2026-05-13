import CoreGraphics
import Foundation
import Testing
@testable import PrivateFoundationModels

@Suite("Vision attachments")
struct AttachmentTests {

    /// Build a minimal solid-color CGImage for tests. The pixel data doesn't
    /// matter; the session never inspects it, it just forwards the reference.
    private func solidImage(width: Int = 4, height: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - 1. respond(to:image:) plumbs the image to the backend

    @Test func respondWithImageReachesBackend() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(text: "I see a red square."))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        let image = solidImage()
        let reply = try await session.respond(to: "Describe this image.", image: image)
        #expect(reply.content == "I see a red square.")
        #expect(stub.lastAttachmentCount == 1)
    }

    // MARK: - 2. streamResponse(to:image:) plumbs the image to the backend

    @Test func streamResponseWithImageReachesBackend() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(chunks: ["A red ", "square."]))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        let image = solidImage()
        let stream = session.streamResponse(to: "Describe.", image: image)
        var snapshots: [String] = []
        for try await snapshot in stream { snapshots.append(snapshot.content) }
        let final = try await stream.collect()

        #expect(snapshots.last == "A red square.")
        #expect(final.content == "A red square.")
        #expect(stub.lastAttachmentCount == 1)
    }

    // MARK: - 3. respond(to:) without image sends zero attachments

    @Test func respondWithoutImageSendsZeroAttachments() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(text: "Hi."))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        _ = try await session.respond(to: "Hi")
        #expect(stub.lastAttachmentCount == 0)
    }

    // MARK: - 4. nil image is equivalent to text-only

    @Test func respondWithNilImageSendsZeroAttachments() async throws {
        let stub = StubBackend()
        stub.enqueue(.init(text: "Hi."))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        let nilImage: CGImage? = nil
        _ = try await session.respond(to: "Hi", image: nilImage)
        #expect(stub.lastAttachmentCount == 0)
    }

    // MARK: - 5. Text-only backend (no override) silently drops the image

    @Test func textOnlyBackendDropsImageWithoutError() async throws {
        let stub = StubBackend()
        stub.implementsAttachments = false   // exercise the default extension
        stub.enqueue(.init(text: "text only"))
        let model = SystemLanguageModel(backend: stub)
        let session = LanguageModelSession(model: model)

        let image = solidImage()
        let reply = try await session.respond(to: "Describe.", image: image)
        #expect(reply.content == "text only")
        // Default extension drops attachments before calling generate(), so
        // the stub never updates the count above its initial zero.
        #expect(stub.lastAttachmentCount == 0)
    }
}
