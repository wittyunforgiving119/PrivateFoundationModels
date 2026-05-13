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
        var charsPerSec: Double {
            totalMs > 0 ? Double(chars) / (totalMs / 1000.0) : 0
        }
    }

    struct Plan {
        let label: String
        let isAvailable: () -> Bool
        let load: () async throws -> any LanguageModelBackend
    }

    private var plans: [Plan] {
        var out: [Plan] = []

        #if canImport(FoundationModels)
        // Apple FM only on iOS 26+ with Apple Intelligence on
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

        return out
    }

    // MARK: - Run

    private let prompt = "Write a single-sentence Swift fact in under 30 words."
    private let maxTokens = 80
    private let iterations = 3

    func runAll() async {
        status = .running(stage: "Starting…")
        log = ""
        csv = "timestamp,hardware,backend,load_ms,ttft_ms,total_ms,output_chars,chars_per_sec\n"
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
            let row = Row(backend: plan.label, loadMs: loadMs,
                           ttftMs: medTTFT, totalMs: medTotal, chars: Int(medChars))
            rows.append(row)
            let escaped = plan.label.replacingOccurrences(of: "\"", with: "\"\"")
            let hwEscaped = hw.replacingOccurrences(of: "\"", with: "\"\"")
            let csvRow = String(format: "%@,\"%@\",\"%@\",%.0f,%.0f,%.0f,%.0f,%.1f\n",
                                 timestamp, hwEscaped, escaped, loadMs, medTTFT, medTotal, medChars, cps)
            csv += csvRow
            appendLog(String(format: "  → median: ttft %.0f ms, throughput %.1f chars/sec", medTTFT, cps))
        }

        // Persist CSV to Documents so user can find it via Files app.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("pfm-bench-\(Int(Date().timeIntervalSince1970)).csv")
            try? csv.data(using: .utf8)?.write(to: url)
            appendLog("\nCSV saved: \(url.lastPathComponent)")
        }
        UIPasteboard.general.string = csv
        appendLog("CSV copied to clipboard.")
        status = .done
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
                                        Text(String(format: "load %.0f ms · ttft %.0f ms · total %.0f ms · %d chars · %.1f chars/sec",
                                                     r.loadMs, r.ttftMs, r.totalMs, r.chars, r.charsPerSec))
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
