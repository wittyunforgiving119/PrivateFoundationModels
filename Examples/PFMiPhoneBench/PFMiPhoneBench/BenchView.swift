import SwiftUI
import PrivateFoundationModels
import PrivateFoundationModelsCoreML
import PrivateFoundationModelsMLX
#if canImport(FoundationModels)
import PrivateFoundationModelsApple
#endif

@MainActor
final class BenchRunner: ObservableObject {

    enum Status: Equatable {
        case idle
        case running(stage: String)
        case done
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var log: String = ""
    @Published var csv: String = ""
    @Published var rows: [Row] = []

    struct Row: Identifiable, Equatable {
        let id = UUID()
        let backend: String
        let loadMs: Double
        let ttftMs: Double
        let totalMs: Double
        let chars: Int
        // End-to-end chars/sec — includes prefill.
        var charsPerSec: Double {
            totalMs > 0 ? Double(chars) / (totalMs / 1000.0) : 0
        }
        // Decode-only chars/sec — strips prefill so this reflects pure
        // generation rate. Use this when comparing runtimes against
        // each other, since a long TTFT shouldn't double-penalize.
        var decodeCharsPerSec: Double {
            let decodeMs = totalMs - ttftMs
            return decodeMs > 0 ? Double(chars) / (decodeMs / 1000.0) : 0
        }
    }

    struct Plan {
        let label: String
        let isAvailable: () -> Bool
        let load: () async throws -> any LanguageModelBackend
    }

    /// Set of plans to run. Flip `runFullMatrix` to true to get the
    /// 5-backend Apple FM + CoreML/MLX Qwen + LFM2.5 + Gemma sweep;
    /// false runs just the Gemma 4 E2B head-to-head (CoreML sideload
    /// vs MLX download) which is the comparison we publish.
    private static let runFullMatrix = false

    private var plans: [Plan] {
        var out: [Plan] = []

        if Self.runFullMatrix {
            #if canImport(FoundationModels)
            out.append(Plan(
                label: "Apple FM (.general)",
                isAvailable: {
                    if #available(iOS 26.0, *) {
                        return AppleFoundationModel.isAvailable
                    }
                    return false
                },
                load: {
                    if #available(iOS 26.0, *) {
                        return AppleFoundationModel.load()
                    }
                    throw NSError(domain: "PFMBench", code: 1)
                }
            ))
            #endif
            out.append(Plan(
                label: "CoreML / ANE (LFM2.5-350M)",
                isAvailable: { true },
                load: {
                    try await CoreMLLanguageModel.load(.lfm2_5_350M) { @Sendable _ in }
                }
            ))
            out.append(Plan(
                label: "CoreML / ANE (Qwen3.5-0.8B)",
                isAvailable: { true },
                load: {
                    try await CoreMLLanguageModel.load(.qwen3_5_0_8B) { @Sendable _ in }
                }
            ))
            out.append(Plan(
                label: "MLX / GPU (Qwen3.5-0.8B-MLX-4bit)",
                isAvailable: { true },
                load: {
                    try await MLXLanguageModel.load(
                        .custom("mlx-community/Qwen3.5-0.8B-MLX-4bit")
                    ) { _ in }
                }
            ))
        }

        // Gemma 4 E2B head-to-head.
        // CoreML side: `devicectl`-pushed bundle under Documents/Models/.
        // MLX side: downloads `mlx-community/gemma-4-e2b-it-4bit` on first run.
        out.append(Plan(
            label: "CoreML / ANE (Gemma-4-E2B, sideload)",
            isAvailable: { Self.sideloadedGemmaDir() != nil },
            load: {
                guard let dir = Self.sideloadedGemmaDir() else {
                    throw NSError(
                        domain: "PFMBench", code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Sideload not found: Documents/Models/gemma4-e2b/"]
                    )
                }
                return try await CoreMLLanguageModel.load(
                    localBundle: dir,
                    identifier: "coreml-local://gemma4-e2b"
                ) { @Sendable _ in }
            }
        ))

        out.append(Plan(
            label: "MLX / GPU (Gemma-4-E2B-4bit)",
            isAvailable: { true },
            load: {
                try await MLXLanguageModel.load(
                    .custom("mlx-community/gemma-4-e2b-it-4bit")
                ) { _ in }
            }
        ))

        return out
    }

    /// Locate the sideloaded Gemma 4 E2B bundle. We accept either of
    /// two layouts that `xcrun devicectl device copy to` can produce:
    ///
    ///   Documents/Models/gemma4-e2b/model_config.json   (subdir form)
    ///   Documents/Models/model_config.json              (flat form,
    ///                                                    what devicectl
    ///                                                    actually does
    ///                                                    when destination
    ///                                                    is `Models/`)
    ///
    /// Returns nil when neither layout has a `model_config.json`, so
    /// the plan can be skipped without the user noticing.
    static func sideloadedGemmaDir() -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidates = [
            docs.appendingPathComponent("Models/gemma4-e2b", isDirectory: true),
            docs.appendingPathComponent("Models", isDirectory: true),
        ]
        let fm = FileManager.default
        for dir in candidates {
            let cfg = dir.appendingPathComponent("model_config.json")
            if fm.fileExists(atPath: cfg.path) { return dir }
        }
        return nil
    }

    // MARK: - Run

    private let prompt = "Write a single-sentence Swift fact in under 30 words."
    private let maxTokens = 80
    private let iterations = 3

    func runAll() async {
        status = .running(stage: "Starting…")
        log = ""
        csv = "timestamp,hardware,backend,load_ms,ttft_ms,total_ms,output_chars,chars_per_sec,decode_chars_per_sec\n"
        rows = []
        let hw = deviceLabel()
        let timestamp = ISO8601DateFormatter().string(from: Date())

        for plan in plans {
            guard plan.isAvailable() else {
                appendLog("[skip] \(plan.label) — not available on this device")
                continue
            }
            status = .running(stage: "Loading \(plan.label)…")
            appendLog("\n=== \(plan.label) ===")
            let loadStart = ContinuousClock.now
            let backend: any LanguageModelBackend
            do {
                backend = try await plan.load()
            } catch {
                appendLog("  load failed: \(error.localizedDescription)")
                continue
            }
            let load = ContinuousClock.now - loadStart
            let loadMs = ms(load)
            appendLog(String(format: "  loaded in %.0f ms", loadMs))

            SystemLanguageModel.default = SystemLanguageModel(backend: backend)
            // warmup (untimed)
            _ = try? await runOne(timed: false)
            var ttfts: [Double] = []
            var totals: [Double] = []
            var chars: [Int] = []
            for i in 1...iterations {
                status = .running(stage: "\(plan.label) iter \(i)/\(iterations)")
                if let r = try? await runOne(timed: true) {
                    ttfts.append(r.ttft)
                    totals.append(r.total)
                    chars.append(r.chars)
                    appendLog(String(format: "  iter %d: ttft %.0f ms, total %.0f ms, %d chars", i, r.ttft, r.total, r.chars))
                }
            }
            let medTTFT = median(ttfts)
            let medTotal = median(totals)
            let medChars = Double(median(chars))
            let cps = medTotal > 0 ? medChars / (medTotal / 1000.0) : 0
            let decodeMs = medTotal - medTTFT
            let decodeCps = decodeMs > 0 ? medChars / (decodeMs / 1000.0) : 0
            let row = Row(backend: plan.label, loadMs: loadMs,
                           ttftMs: medTTFT, totalMs: medTotal, chars: Int(medChars))
            rows.append(row)
            let escaped = plan.label.replacingOccurrences(of: "\"", with: "\"\"")
            let hwEscaped = hw.replacingOccurrences(of: "\"", with: "\"\"")
            let csvRow = String(format: "%@,\"%@\",\"%@\",%.0f,%.0f,%.0f,%.0f,%.1f,%.1f\n",
                                 timestamp, hwEscaped, escaped, loadMs, medTTFT, medTotal, medChars, cps, decodeCps)
            csv += csvRow
            appendLog(String(format: "  → median: ttft %.0f ms, %.1f cps E2E (%.1f cps decode-only)",
                              medTTFT, cps, decodeCps))

            // Incremental save: persist what we have after every
            // backend so a later crash / hang / kill doesn't lose
            // earlier rows. The file is overwritten each time.
            persistCSV()
            UIPasteboard.general.string = csv
        }

        UIPasteboard.general.string = csv
        appendLog("CSV copied to clipboard.")
        status = .done
    }

    /// Overwrite the canonical Documents CSV with whatever rows are
    /// currently accumulated. Safe to call between every backend.
    private func persistCSV() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let url = docs.appendingPathComponent("pfm-bench-latest.csv")
        try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func runOne(timed: Bool) async throws -> (ttft: Double, total: Double, chars: Int) {
        let session = LanguageModelSession(instructions: Instructions("Be brief."))
        let opts = GenerationOptions(temperature: 0.0, maximumResponseTokens: maxTokens)
        let start = ContinuousClock.now
        var firstAt: ContinuousClock.Instant?
        var last = ""
        for try await snapshot in session.streamResponse(to: prompt, options: opts) {
            let t = snapshot.content
            if firstAt == nil, !t.isEmpty { firstAt = ContinuousClock.now }
            last = t
        }
        let end = ContinuousClock.now
        let total = ms(end - start)
        let ttft = firstAt.map { ms($0 - start) } ?? total
        return (ttft, total, last.count)
    }

    // MARK: - Helpers

    private func appendLog(_ s: String) {
        log += s + "\n"
    }

    private func ms(_ d: Duration) -> Double {
        let (s, atto) = d.components
        return (Double(s) + Double(atto) / 1e18) * 1000
    }

    private func median<T: Comparable & BinaryFloatingPoint>(_ xs: [T]) -> T {
        guard !xs.isEmpty else { return 0 }
        return xs.sorted()[xs.count / 2]
    }
    private func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        return xs.sorted()[xs.count / 2]
    }

    private func deviceLabel() -> String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        let model = String(cString: buf)
        // hw.machine on iOS returns "iPhone17,1" style ids. Include OS for
        // readability when uploaded.
        return "\(model) / iOS \(UIDevice.current.systemVersion)"
    }
}

struct BenchView: View {
    @StateObject private var runner = BenchRunner()
    @State private var showShare = false
    @State private var didAutoStart = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(statusText).font(.headline)
                        Spacer()
                        Button(action: { Task { await runner.runAll() } }) {
                            switch runner.status {
                            case .idle, .done, .failed: Label("Run all", systemImage: "play.fill")
                            case .running: Label("Running…", systemImage: "hourglass")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                    }

                    if !runner.rows.isEmpty {
                        GroupBox("Results (median of \(3) iterations)") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(runner.rows) { r in
                                    VStack(alignment: .leading) {
                                        Text(r.backend).font(.subheadline.bold())
                                        Text(String(format: "load %.0f ms · ttft %.0f ms · total %.0f ms · %d chars",
                                                     r.loadMs, r.ttftMs, r.totalMs, r.chars))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(String(format: "%.1f chars/sec E2E  ·  %.1f chars/sec decode-only",
                                                     r.charsPerSec, r.decodeCharsPerSec))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if !runner.csv.isEmpty {
                        Button("Share CSV") { showShare = true }
                            .buttonStyle(.bordered)
                    }

                    GroupBox("Log") {
                        Text(runner.log.isEmpty ? "Tap Run all to start." : runner.log)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("PFM iPhone Bench")
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [runner.csv])
            }
            .onAppear {
                // Keep the screen awake while the bench runs.
                UIApplication.shared.isIdleTimerDisabled = true
                // Auto-kick the bench once on first appearance so the
                // device can be left alone for the entire run.
                guard !didAutoStart else { return }
                didAutoStart = true
                Task {
                    // Small delay so SwiftUI finishes laying out before
                    // the bench monopolizes the main actor / GPU.
                    try? await Task.sleep(for: .seconds(2))
                    if case .idle = runner.status {
                        await runner.runAll()
                    }
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .running = runner.status { return true }
        return false
    }

    private var statusText: String {
        switch runner.status {
        case .idle:               return "Ready"
        case .running(let stage): return stage
        case .done:               return "Done — CSV copied + saved"
        case .failed(let e):      return "Failed: \(e)"
        }
    }
}

// Wrap UIActivityViewController so the user can Share CSV → AirDrop /
// Mail / Files / Notes / wherever.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
