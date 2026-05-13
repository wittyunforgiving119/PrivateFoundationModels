import Foundation
import PrivateFoundationModels
import PrivateFoundationModelsMLX

// MARK: - CLI

struct CLI {
    var modelID: String = "mlx-community/Qwen3.5-0.8B-MLX-4bit"
    var prompt: String = "In one short sentence, what is the capital of France?"
    var maxTokens: Int = 80

    static func parse() -> CLI {
        var cli = CLI()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--model":     if let v = args.next() { cli.modelID = v }
            case "--prompt":    if let v = args.next() { cli.prompt = v }
            case "--max":       if let v = args.next(), let n = Int(v) { cli.maxTokens = n }
            case "-h", "--help":
                printHelp(); exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown argument: \(arg)\n".utf8))
                printHelp(); exit(64)
            }
        }
        return cli
    }

    static func printHelp() {
        print("""
        pfm-mlx-smoke — minimal end-to-end check for the MLX backend.

        USAGE:
            swift run -c release pfm-mlx-smoke [OPTIONS]

        OPTIONS:
            --model <repo>   mlx-community/* repo (default: Qwen3.5-0.8B-MLX-4bit).
            --prompt <text>  User prompt (default: "capital of France").
            --max <n>        Max response tokens (default: 80).
            -h, --help       Print this help.
        """)
    }
}

// MARK: - Pretty printing

func banner(_ title: String) {
    let line = String(repeating: "─", count: 78)
    print("\n" + line)
    print(" \(title)")
    print(line)
}

func ok(_ message: String)   { print("  ✓ \(message)") }
func info(_ message: String) { print("  • \(message)") }
func fail(_ message: String) { print("  ✗ \(message)") }

func ms(_ duration: Duration) -> String {
    let (s, attoseconds) = duration.components
    let total = Double(s) + Double(attoseconds) / 1e18
    return String(format: "%.0f ms", total * 1000)
}

// MARK: - Main (top-level async — main.swift form, no @main)

let cli = CLI.parse()

banner("PrivateFoundationModelsMLX — end-to-end smoke test")
info("repo:    \(cli.modelID)")
info("prompt:  \(cli.prompt)")
info("max:     \(cli.maxTokens) tokens")

let backend: MLXBackend
do {
    banner("1. Load model")
    let start = ContinuousClock.now
    backend = try await MLXLanguageModel.load(.custom(cli.modelID)) { stage in
        info(stage)
    }
    ok("loaded in \(ms(ContinuousClock.now - start))")
} catch {
    fail("load failed: \(error)")
    exit(1)
}

SystemLanguageModel.default = SystemLanguageModel(backend: backend)
let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: cli.maxTokens)

do {
    banner("2. respond(to:)")
    let session = LanguageModelSession(instructions: "Be brief.")
    let start = ContinuousClock.now
    let response = try await session.respond(to: cli.prompt, options: options)
    ok("respond() returned in \(ms(ContinuousClock.now - start))")
    print("\n--- response ---\n\(response.content)\n----------------")
} catch {
    fail("respond failed: \(error)")
    exit(2)
}

do {
    banner("3. streamResponse(to:)")
    let session = LanguageModelSession(instructions: "Be brief.")
    let stream = session.streamResponse(to: cli.prompt, options: options)
    print("\n--- streaming ---")
    var lastLen = 0
    for try await snapshot in stream {
        let text = snapshot.content
        if text.count > lastLen {
            let delta = String(text.suffix(text.count - lastLen))
            print(delta, terminator: "")
            lastLen = text.count
        }
    }
    print("\n-----------------")
    ok("stream completed")
} catch {
    fail("stream failed: \(error)")
    exit(3)
}

banner("All smoke checks passed.")
exit(0)
