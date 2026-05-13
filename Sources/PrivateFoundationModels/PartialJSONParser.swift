import Foundation

/// State-tracking JSON parser specialized for *partial* output — i.e. the
/// running cumulative buffer of a streaming response. Returns the longest
/// prefix of the input that can be turned into a valid JSON object by
/// appending the right closing brackets at the end.
///
/// Approach:
///
/// 1. Walk the input character by character with an explicit stack of
///    open `{` / `[` brackets, each tagged with a per-container parser
///    state (expecting key / expecting value / etc.).
/// 2. Every time a *value* finishes at depth ≥ 1 (a closed string used
///    as a value, a finished number, a `true`/`false`/`null` literal, or
///    a closed sub-object / sub-array), record the index right after it
///    as a "safe truncation point" — that's the latest spot where we
///    can cut the buffer, append the appropriate closing brackets, and
///    still produce well-formed JSON.
/// 3. At end of input, if the buffer didn't already form a complete
///    top-level object, return `<prefix up to last safe point> + closers`.
enum PartialJSONParser {

    static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        enum State { case expectingKey, afterKey, expectingValue, afterValue }
        struct Frame { let open: Character; var state: State }

        var stack: [Frame] = []
        var inString = false
        var escape = false
        var lastSafe: String.Index?
        var lastSafeStack: [Frame] = []

        func recordSafe(at idx: String.Index) {
            guard !stack.isEmpty else { return }
            lastSafe = idx
            lastSafeStack = stack
        }

        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            let nextIdx = text.index(after: idx)

            if escape {
                escape = false
                idx = nextIdx
                continue
            }

            if inString {
                if ch == "\\" {
                    escape = true
                    idx = nextIdx
                    continue
                }
                if ch == "\"" {
                    inString = false
                    // Was the string a key or a value?
                    guard let top = stack.last else {
                        idx = nextIdx
                        continue
                    }
                    switch top.state {
                    case .expectingKey:
                        stack[stack.count - 1].state = .afterKey
                    case .expectingValue:
                        stack[stack.count - 1].state = .afterValue
                        recordSafe(at: nextIdx)
                    case .afterKey, .afterValue:
                        // Stray string token; tolerate, no state change.
                        break
                    }
                }
                idx = nextIdx
                continue
            }

            switch ch {
            case "\"":
                inString = true
                idx = nextIdx

            case "{":
                stack.append(Frame(open: "{", state: .expectingKey))
                idx = nextIdx

            case "[":
                stack.append(Frame(open: "[", state: .expectingValue))
                idx = nextIdx

            case "}":
                guard let top = stack.last, top.open == "{" else { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    // Complete top-level object.
                    return String(text[start...idx])
                }
                stack[stack.count - 1].state = .afterValue
                recordSafe(at: nextIdx)
                idx = nextIdx

            case "]":
                guard let top = stack.last, top.open == "[" else { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    // Top-level array isn't an "object" — bail.
                    return nil
                }
                stack[stack.count - 1].state = .afterValue
                recordSafe(at: nextIdx)
                idx = nextIdx

            case ":":
                if let top = stack.last, top.state == .afterKey {
                    stack[stack.count - 1].state = .expectingValue
                }
                idx = nextIdx

            case ",":
                if let top = stack.last, top.state == .afterValue {
                    stack[stack.count - 1].state =
                        (top.open == "{") ? .expectingKey : .expectingValue
                }
                idx = nextIdx

            case "t":
                if let end = scanLiteral("true", in: text, from: idx) {
                    if let top = stack.last, top.state == .expectingValue {
                        stack[stack.count - 1].state = .afterValue
                        recordSafe(at: end)
                    }
                    idx = end
                } else {
                    idx = nextIdx
                }

            case "f":
                if let end = scanLiteral("false", in: text, from: idx) {
                    if let top = stack.last, top.state == .expectingValue {
                        stack[stack.count - 1].state = .afterValue
                        recordSafe(at: end)
                    }
                    idx = end
                } else {
                    idx = nextIdx
                }

            case "n":
                if let end = scanLiteral("null", in: text, from: idx) {
                    if let top = stack.last, top.state == .expectingValue {
                        stack[stack.count - 1].state = .afterValue
                        recordSafe(at: end)
                    }
                    idx = end
                } else {
                    idx = nextIdx
                }

            case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                var end = nextIdx
                while end < text.endIndex, isNumberChar(text[end]) {
                    end = text.index(after: end)
                }
                if end == text.endIndex {
                    // Number runs to EOF — unsafe to truncate (next byte
                    // could extend the value, e.g. 12 → 123 or 12.5).
                    idx = end
                } else {
                    if let top = stack.last, top.state == .expectingValue {
                        stack[stack.count - 1].state = .afterValue
                        recordSafe(at: end)
                    }
                    idx = end
                }

            default:
                idx = nextIdx
            }
        }

        // Reached EOF without closing the top object. Return a best-effort
        // truncation if we've ever crossed a safe value-completion point.
        guard let safe = lastSafe else { return nil }
        var candidate = String(text[start..<safe])
        for frame in lastSafeStack.reversed() {
            candidate.append(frame.open == "{" ? "}" : "]")
        }
        return candidate
    }

    private static func scanLiteral(_ literal: String, in text: String, from start: String.Index) -> String.Index? {
        var t = start
        for ch in literal {
            guard t < text.endIndex, text[t] == ch else { return nil }
            t = text.index(after: t)
        }
        return t
    }

    private static func isNumberChar(_ c: Character) -> Bool {
        if c.isNumber { return true }
        switch c {
        case ".", "e", "E", "+", "-": return true
        default: return false
        }
    }
}
