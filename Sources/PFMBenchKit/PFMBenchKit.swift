// PFMBenchKit — backend-agnostic single-prompt latency / throughput
// harness. Each `BenchRow` captures load_ms, time-to-first-token,
// total_ms, character count, and chars/sec across a small number of
// iterations so the per-run jitter shows up in the spread.
//
// Used by the per-backend pfm-bench-* executables. Each of those
// loads its backend, installs it as `SystemLanguageModel.default`,
// then calls `Bench.runAll(label:loadMs:)` which prints a
// machine-readable row plus the markdown summary.

import Foundation
import PrivateFoundationModels

public struct BenchOptions {
    /// Identical across all backends so the row is apples-to-apples.
    public static let prompt = "Write a single-sentence Swift fact in under 30 words."
    public static let maxTokens = 80
    public static let temperature: Double = 0.0
    public static let iterations = 3
}

/// Curated prompts for the multi-language bench. Each prompt asks the
/// same task — produce a one-sentence Swift fact in ≤ 30 words — in
/// the target language. Output length differences between rows show
/// where the tokenizer + model are stronger / weaker per language.
public enum BenchLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case japanese = "ja"
    case chinese_simplified = "zh"
    case korean = "ko"
    case spanish = "es"

    public var prompt: String {
        switch self {
        case .english:
            return "Write a single-sentence Swift fact in under 30 words."
        case .japanese:
            return "Swift について、30 語以内の一文で事実を一つ書いてください。"
        case .chinese_simplified:
            return "用一句不超过 30 字的话写一个关于 Swift 的事实。"
        case .korean:
            return "Swift에 대한 30단어 이내의 사실 한 문장을 작성하세요."
        case .spanish:
            return "Escribe un hecho sobre Swift en una sola oración de menos de 30 palabras."
        }
    }

    public var label: String {
        switch self {
        case .english:             return "English"
        case .japanese:            return "日本語"
        case .chinese_simplified:  return "中文"
        case .korean:              return "한국어"
        case .spanish:             return "Español"
        }
    }
}

/// Multi-language variant of `Bench.runAll`. Runs the harness once per
/// language and returns one row per language so callers can compare
/// tokenizer / model strength across languages.
public extension Bench {
    static func runAllLanguages(
        backendLabel: String,
        loadMs: Double,
        languages: [BenchLanguage] = BenchLanguage.allCases,
        tokenCounter: ((String) async -> Int?)? = nil
    ) async -> [BenchRow] {
        var rows: [BenchRow] = []
        for lang in languages {
            let row = await runOne(
                label: "\(backendLabel) — \(lang.label)",
                loadMs: loadMs,
                prompt: lang.prompt,
                tokenCounter: tokenCounter
            )
            rows.append(row)
        }
        return rows
    }

    /// Same as `runAll(label:loadMs:)` but with a custom prompt.
    static func runOne(
        label: String,
        loadMs: Double,
        prompt: String,
        tokenCounter: ((String) async -> Int?)? = nil
    ) async -> BenchRow {
        var ttfts: [Double] = []
        var totals: [Double] = []
        var chars: [Int] = []
        var tokens: [Int] = []
        _ = try? await runOnce(timed: false, prompt: prompt)
        for _ in 0..<BenchOptions.iterations {
            if let r = try? await runOnce(timed: true, prompt: prompt) {
                ttfts.append(r.ttft)
                totals.append(r.total)
                chars.append(r.chars)
                if let counter = tokenCounter, let t = await counter(r.text) {
                    tokens.append(t)
                }
            }
        }
        return BenchRow(
            label: label, loadMs: loadMs,
            ttftMs: ttfts, totalMs: totals, outputChars: chars,
            outputTokens: tokens.count == chars.count ? tokens : []
        )
    }

    private static func runOnce(timed: Bool, prompt: String) async throws
        -> (ttft: Double, total: Double, chars: Int, text: String)
    {
        let session = LanguageModelSession(instructions: Instructions("Be brief."))
        let options = GenerationOptions(
            temperature: BenchOptions.temperature,
            maximumResponseTokens: BenchOptions.maxTokens
        )
        let start = ContinuousClock.now
        var firstAt: ContinuousClock.Instant?
        var lastText = ""
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            let text = snapshot.content
            if firstAt == nil, !text.isEmpty {
                firstAt = ContinuousClock.now
            }
            lastText = text
        }
        let end = ContinuousClock.now
        let totalMs = millisRange(start, end)
        let ttftMs = firstAt.map { millisRange(start, $0) } ?? totalMs
        return (ttftMs, totalMs, lastText.count, lastText)
    }

    private static func millisRange(
        _ start: ContinuousClock.Instant,
        _ end: ContinuousClock.Instant
    ) -> Double {
        let dur = end - start
        let (s, atto) = dur.components
        return (Double(s) + Double(atto) / 1e18) * 1000
    }
}

public struct BenchRow {
    public var label: String
    public var loadMs: Double
    public var ttftMs: [Double]   // time-to-first-token per iteration
    public var totalMs: [Double]  // streamResponse wall time per iteration
    public var outputChars: [Int]
    /// Real token counts from the backend's own tokenizer, one per
    /// iteration. Empty when the backend can't expose its tokenizer
    /// (Apple FM). Aligned with `outputChars` when present.
    public var outputTokens: [Int] = []
}

extension BenchRow {
    /// `chars / (total / 1000)`. End-to-end user-perceived throughput
    /// — TTFT counts against this number, so a backend with slow
    /// prefill but fast decode looks slower than it actually is.
    /// Useful for "how does this feel to the user."
    public var medianCharsPerSec: Double {
        let medTotal = median(totalMs)
        let medChars = Double(median(outputChars))
        return medTotal > 0 ? medChars / (medTotal / 1000.0) : 0
    }

    /// `chars / ((total - ttft) / 1000)`. Decode-only throughput —
    /// strips prefill out so the result reflects the runtime's pure
    /// token-generation rate. Use this for apples-to-apples runtime
    /// comparisons.
    public var medianDecodeCharsPerSec: Double {
        let medTotal = median(totalMs)
        let medTTFT = median(ttftMs)
        let medChars = Double(median(outputChars))
        let decodeMs = medTotal - medTTFT
        return decodeMs > 0 ? medChars / (decodeMs / 1000.0) : 0
    }

    public func summary() -> String {
        let medTTFT = median(ttftMs)
        let medTotal = median(totalMs)
        let medChars = Double(median(outputChars))
        return String(
            format: """
            ────────────────────────────────────────────────────────────────
             %@
            ────────────────────────────────────────────────────────────────
              load:              %.0f ms
              time-to-first-tok: %.0f ms (median, %d runs)
              total respond:     %.0f ms (median)
              output chars:      %.0f (median)
              throughput (E2E):  %.1f chars/sec
              throughput (dec):  %.1f chars/sec (decode-only)
            """,
            label, loadMs,
            medTTFT, ttftMs.count,
            medTotal, medChars,
            medianCharsPerSec, medianDecodeCharsPerSec
        )
    }

    public func markdownRow() -> String {
        let medTTFT = median(ttftMs)
        let medTotal = median(totalMs)
        let medChars = Double(median(outputChars))
        return String(
            format: "| %@ | %.0f ms | %.0f ms | %.0f ms | %.0f | %.1f | %.1f |",
            label, loadMs, medTTFT, medTotal, medChars,
            medianCharsPerSec, medianDecodeCharsPerSec
        )
    }

    /// CSV row with the same columns as `markdownRow`, plus a
    /// hardware label and timestamp so per-machine results from
    /// different contributors collate cleanly into one table.
    public func csvRow(hardware: String, timestamp: String = isoNow()) -> String {
        let medTTFT = median(ttftMs)
        let medTotal = median(totalMs)
        let medChars = Double(median(outputChars))
        // Quote fields that may contain commas / spaces. The label and
        // hardware tag are the only realistic offenders.
        let quotedLabel = "\"\(label.replacingOccurrences(of: "\"", with: "\"\""))\""
        let quotedHW = "\"\(hardware.replacingOccurrences(of: "\"", with: "\"\""))\""
        let tokCell = medianTokens.map { String($0) } ?? ""
        let tpsE2ECell = medianE2ETokensPerSec.map { String(format: "%.1f", $0) } ?? ""
        let tpsDecodeCell = medianDecodeTokensPerSec.map { String(format: "%.1f", $0) } ?? ""
        return String(
            format: "%@,%@,%@,%.0f,%.0f,%.0f,%.0f,%@,%.1f,%.1f,%@,%@",
            timestamp, quotedHW, quotedLabel,
            loadMs, medTTFT, medTotal, medChars,
            tokCell, medianCharsPerSec, medianDecodeCharsPerSec,
            tpsE2ECell, tpsDecodeCell
        )
    }

    public static let csvHeader =
        "timestamp,hardware,backend,load_ms,ttft_ms,total_ms,output_chars,output_tokens,chars_per_sec,decode_chars_per_sec,tok_per_sec_e2e,tok_per_sec_decode"

    public var medianTokens: Int? {
        guard outputTokens.count == outputChars.count, !outputTokens.isEmpty
        else { return nil }
        return median(outputTokens)
    }

    public var medianDecodeTokensPerSec: Double? {
        guard let toks = medianTokens else { return nil }
        let decodeMs = median(totalMs) - median(ttftMs)
        return decodeMs > 0 ? Double(toks) / (decodeMs / 1000.0) : 0
    }

    public var medianE2ETokensPerSec: Double? {
        guard let toks = medianTokens else { return nil }
        let total = median(totalMs)
        return total > 0 ? Double(toks) / (total / 1000.0) : 0
    }
}

/// Convenience for stamping CSV rows.
public func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

/// Auto-detect a human-readable hardware label via sysctl
/// (`machdep.cpu.brand_string` returns "Apple M4 Max" etc.). Falls
/// back to "unknown-mac" when sysctl is unavailable.
public func autoHardwareLabel() -> String {
    var size: size_t = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return "unknown-mac" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    return String(cString: buffer)
}

/// Common CLI output handler. Reads `--csv` and `--csv-append`,
/// `--hardware <label>` (defaults to autoHardwareLabel()) from the
/// process args and emits each row in the requested format(s):
///
/// - Default (no flags): pretty summaries + markdown rows on stdout.
/// - `--csv`:             one CSV row per BenchRow on stdout, with
///                        header on the first line.
/// - `--csv-append PATH`: append rows to PATH; writes header line
///                        if PATH doesn't exist yet. Pretty stdout
///                        output is still emitted alongside.
public func emitBenchOutput(_ rows: [BenchRow]) {
    let args = CommandLine.arguments.dropFirst()
    let csvStdout = args.contains("--csv")
    var csvPath: String?
    var hardware = autoHardwareLabel()
    var it = args.makeIterator()
    while let arg = it.next() {
        if arg == "--csv-append", let p = it.next() { csvPath = p }
        if arg == "--hardware", let h = it.next() { hardware = h }
    }
    let timestamp = isoNow()

    if csvStdout {
        print(BenchRow.csvHeader)
        for row in rows { print(row.csvRow(hardware: hardware, timestamp: timestamp)) }
        return  // CSV-only mode — pretty output suppressed for clean piping
    }

    for row in rows { print(row.summary()) }
    print()
    print("Markdown:")
    for row in rows { print(row.markdownRow()) }

    if let csvPath {
        print()
        print("Appending CSV rows to \(csvPath) (hw=\"\(hardware)\")…")
        for row in rows {
            do {
                try appendCSV(row.csvRow(hardware: hardware, timestamp: timestamp), to: csvPath)
            } catch {
                FileHandle.standardError.write(Data("CSV append failed: \(error)\n".utf8))
            }
        }
    }
}

/// Append a row to a CSV file, writing the header line if the file
/// doesn't exist yet. Used by the `--csv-append <path>` flag so a
/// shared `docs/BENCHMARKS.csv` can grow with contributions from
/// other machines without manual editing.
public func appendCSV(_ row: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let exists = FileManager.default.fileExists(atPath: url.path)
    let payload: String
    if exists {
        payload = row + "\n"
    } else {
        payload = BenchRow.csvHeader + "\n" + row + "\n"
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(payload.utf8))
    try handle.close()
}

private func median<T: Comparable & BinaryFloatingPoint>(_ xs: [T]) -> T {
    let sorted = xs.sorted()
    if sorted.isEmpty { return 0 }
    return sorted[sorted.count / 2]
}

private func median(_ xs: [Int]) -> Int {
    let sorted = xs.sorted()
    if sorted.isEmpty { return 0 }
    return sorted[sorted.count / 2]
}

public enum Bench {

    /// Run `BenchOptions.iterations` warm streaming `respond` calls
    /// against the currently-installed backend. Caller supplies the
    /// label and load time (loading is backend-specific so it stays
    /// outside this kit). Pass `tokenCounter` to capture real token
    /// counts (typically `backend.tokenCount(_:)`); pass `nil` to
    /// fall back to char-only metrics.
    public static func runAll(
        label: String,
        loadMs: Double,
        tokenCounter: ((String) async -> Int?)? = nil
    ) async -> BenchRow {
        var ttfts: [Double] = []
        var totals: [Double] = []
        var chars: [Int] = []
        var tokens: [Int] = []

        // Warmup: one untimed pass so caches / KV state settle.
        _ = try? await runOnce(timed: false)

        for _ in 0..<BenchOptions.iterations {
            if let r = try? await runOnce(timed: true) {
                ttfts.append(r.ttft)
                totals.append(r.total)
                chars.append(r.chars)
                if let counter = tokenCounter, let t = await counter(r.text) {
                    tokens.append(t)
                }
            }
        }

        return BenchRow(
            label: label, loadMs: loadMs,
            ttftMs: ttfts, totalMs: totals, outputChars: chars,
            outputTokens: tokens.count == chars.count ? tokens : []
        )
    }

    private static func runOnce(timed: Bool) async throws
        -> (ttft: Double, total: Double, chars: Int, text: String)
    {
        let session = LanguageModelSession(instructions: Instructions("Be brief."))
        let options = GenerationOptions(
            temperature: BenchOptions.temperature,
            maximumResponseTokens: BenchOptions.maxTokens
        )
        let start = ContinuousClock.now
        var firstAt: ContinuousClock.Instant?
        var lastText = ""

        let stream = session.streamResponse(to: BenchOptions.prompt, options: options)
        for try await snapshot in stream {
            let text = snapshot.content
            if firstAt == nil, !text.isEmpty {
                firstAt = ContinuousClock.now
            }
            lastText = text
        }
        let end = ContinuousClock.now

        let totalMs = millis(start...end)
        let ttftMs = firstAt.map { millis(start...$0) } ?? totalMs
        return (ttftMs, totalMs, lastText.count, lastText)
    }

    private static func millis(_ range: ClosedRange<ContinuousClock.Instant>) -> Double {
        let dur = range.upperBound - range.lowerBound
        let (s, atto) = dur.components
        return (Double(s) + Double(atto) / 1e18) * 1000
    }
}
