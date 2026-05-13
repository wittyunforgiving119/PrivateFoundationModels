import Foundation

/// Safety / policy filter shim. Mirrors `FoundationModels.LanguageModelSession`'s
/// `guardrails:` initializer parameter so call sites that target Apple's
/// framework compile against `PrivateFoundationModels` unchanged.
///
/// v0.2 ships an accept-all no-op: every prompt and response flows through
/// untouched. The Apple FoundationModels framework's own guardrails (when
/// the host runs on iOS 26 and the user picks the `AppleFMBridgeBackend`)
/// still apply at the *backend* layer — they're not bypassed by setting
/// `.default` here. A future minor release will allow per-session policy
/// configuration (block-lists, custom filters) without breaking the
/// `Guardrails.default` shape.
public struct Guardrails: Sendable, Hashable {
    /// Permissive default. Future versions add `strict`, `permissive`, etc.
    public static let `default` = Guardrails()

    public init() {}
}
