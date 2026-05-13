// pfm-mlx-deep — runs the same scenario matrix as pfm-deep, but with
// generation routed through ml-explore/mlx-swift-lm. Diff the two
// outputs to verify backend feature parity for Generable, Tools, and
// (text-only) Multimodal / PromptBuilder paths.
//
//   xcodebuild -scheme pfm-mlx-deep ...
//   pfm-mlx-deep [--model mlx-community/<repo>]

import Foundation
import PFMDeepKit
import PrivateFoundationModels
import PrivateFoundationModelsMLX

func readArg(after flag: String) -> String? {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        if arg == flag { return it.next() }
    }
    return nil
}

func run() async {
    let modelID = readArg(after: "--model") ?? "mlx-community/Qwen3.5-0.8B-MLX-4bit"

    banner("PrivateFoundationModels deep verification — MLX")
    print("  model:          \(modelID)")
    print("  date:           \(Date())")

    do {
        let backend = try await MLXLanguageModel.load(.custom(modelID)) { stage in
            print("  • \(stage)")
        }
        SystemLanguageModel.default = SystemLanguageModel(backend: backend)
    } catch {
        fail("failed to load MLX backend: \(error)")
        exit(1)
    }

    var runner = DeepRunner()
    await runner.runAll()
    runner.summarize()
}

await run()
