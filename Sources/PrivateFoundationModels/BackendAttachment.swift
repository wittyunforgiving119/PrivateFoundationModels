import CoreGraphics
import Foundation

/// Non-textual input passed alongside a transcript to backends that support
/// multimodal models. v0.2 ships image; audio is on the v0.8 roadmap.
///
/// Backends without a use for an attachment ignore it via the default
/// `LanguageModelBackend` implementation — code written for an Apple FM
/// `LanguageModelSession.respond(to:options:)` shape keeps compiling.
public struct BackendAttachment: Sendable {
    public enum Kind: @unchecked Sendable {
        case image(CGImage)
    }

    public let kind: Kind

    public init(image: CGImage) {
        self.kind = .image(image)
    }
}
