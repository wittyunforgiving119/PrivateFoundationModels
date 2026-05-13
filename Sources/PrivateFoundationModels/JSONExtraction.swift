import Foundation

/// Shared helpers for pulling a JSON value out of a model's raw text. The
/// problem is the same in two places: the CoreML backend's non-streaming
/// `parse()`, and the session's streaming `Generable` decode path. Both
/// must tolerate the four shapes a model commonly produces:
///
/// 1. Bare JSON object: `{"a":1}`
/// 2. JSON wrapped in a Markdown code fence: ``` ```json\n{...}\n``` ```
/// 3. JSON with leading/trailing prose: `"Sure, here it is: {...} — done!"`
/// 4. Truncated JSON during streaming: `{"a":1,"b":` (we leave this alone
///    so the streaming decoder can try again next chunk).
public enum JSONExtraction {

    /// Best-effort extraction of a single complete top-level JSON object
    /// from `text`. Returns `nil` if no balanced `{ ... }` is present.
    /// Strips Markdown code-fence wrappers AND `<think>...</think>`
    /// reasoning blocks (Qwen3 / DeepSeek-R1 style "thinking" models)
    /// as preprocessing passes.
    public static func extractObject(_ text: String) -> String? {
        let dethought = stripThinkBlocks(text)
        let unfenced = stripCodeFence(dethought)
        return firstBalancedObject(in: unfenced)
    }

    /// Strip `<think>...</think>` (and `<thinking>...</thinking>`) blocks
    /// emitted by reasoning models. The thinking content is the model's
    /// scratchpad; we want the final answer that follows.
    public static func stripThinkBlocks(_ text: String) -> String {
        var s = text
        for tag in ["think", "thinking"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            while let openRange = s.range(of: open),
                  let closeRange = s.range(of: close, range: openRange.upperBound..<s.endIndex) {
                s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streaming-aware variant of `extractObject`. Returns the longest
    /// prefix of the input that can be closed into a syntactically valid
    /// JSON object by appending closing brackets, or `nil` if nothing
    /// usable has arrived yet.
    ///
    /// Example: given `{"a":"hello","b":12.5,"c":tr`, this returns
    /// `{"a":"hello","b":12.5}` — the trailing `"c":tr` is incomplete so
    /// we truncate to the last "value just finished" boundary and close
    /// the open brace.
    ///
    /// Used by `LanguageModelSession.streamResponse(to:generating:)` so
    /// callers see snapshot updates as soon as one field's value parses,
    /// not only after the whole object closes.
    public static func extractPartialObject(_ text: String) -> String? {
        let dethought = stripThinkBlocks(text)
        let unfenced = stripCodeFence(dethought)
        return PartialJSONParser.firstObject(in: unfenced)
    }

    /// Strip a leading ``` or ```language fence and the trailing ``` fence
    /// if both are present. Preserves the inner content verbatim. Returns
    /// `text` unchanged when no fence is detected.
    public static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        // Drop the opening fence (including an optional language tag like
        // ```json) up to and including the first newline.
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        } else {
            t = String(t.dropFirst(3))
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Walk `text` and return the substring between the first `{` and the
    /// matching `}` that balances it. String-aware (skips braces inside
    /// double-quoted strings) and escape-aware. `nil` if no balanced
    /// object is present.
    public static func firstBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escape {
                escape = false
            } else if ch == "\\" && inString {
                escape = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
