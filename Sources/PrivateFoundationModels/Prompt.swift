import Foundation

/// A composable user message. Mirrors `FoundationModels.Prompt`.
///
/// `Prompt` can be built from a plain string, a string literal, or a result
/// builder that concatenates segments with newlines. The shape is what
/// Apple's `LanguageModelSession.respond(options:prompt:)` overload
/// expects so trailing-closure call sites compile against either framework.
///
/// ```swift
/// let response = try await session.respond {
///     "Translate the following text into French:"
///     userInput
/// }
/// ```
public struct Prompt: Sendable, Hashable, Codable {
    /// The text content the model will see. Multiple segments are joined
    /// with double newlines by the `@PromptBuilder` to keep them
    /// semantically separated.
    public let text: String

    public init(_ text: String) {
        self.text = text
    }
}

extension Prompt: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.text = value
    }
}

extension Prompt: CustomStringConvertible {
    public var description: String { text }
}

/// Result-builder shim that mirrors Apple's `@PromptBuilder`. Accepts
/// string literals, `Prompt` values, and the usual conditional /
/// optional branches.
@resultBuilder
public enum PromptBuilder {
    public static func buildBlock(_ components: Prompt...) -> Prompt {
        Prompt(components.map(\.text).joined(separator: "\n\n"))
    }

    public static func buildBlock(_ components: String...) -> Prompt {
        Prompt(components.joined(separator: "\n\n"))
    }

    public static func buildExpression(_ expression: String) -> Prompt {
        Prompt(expression)
    }

    public static func buildExpression(_ expression: Prompt) -> Prompt {
        expression
    }

    public static func buildEither(first component: Prompt) -> Prompt { component }
    public static func buildEither(second component: Prompt) -> Prompt { component }
    public static func buildOptional(_ component: Prompt?) -> Prompt {
        component ?? Prompt("")
    }
    public static func buildArray(_ components: [Prompt]) -> Prompt {
        Prompt(components.map(\.text).joined(separator: "\n\n"))
    }
}
