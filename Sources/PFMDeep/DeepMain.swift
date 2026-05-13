// pfm-deep — exercises every Generable / Tool / Multimodal scenario in
// PFMDeepKit against a real CoreML-LLM backed model. The matching
// pfm-mlx-deep executable runs the same matrix against an MLX-Swift
// backed model, so the two outputs can be diffed for parity.
//
//   swift run -c release pfm-deep [--model lfm2.5-350m]

import Foundation
import PFMDeepKit
import PrivateFoundationModels
import PrivateFoundationModelsCoreML

@main
struct DeepMain {
    static func main() async {
        let modelID = readArg(after: "--model") ?? "lfm2.5-350m"

        banner("PrivateFoundationModels deep verification — CoreML")
        print("  model:          \(modelID)")
        print("  date:           \(Date())")

        let catalog: CoreMLLanguageModel.Catalog = {
            switch modelID.lowercased() {
            case "lfm2.5-350m": return .lfm2_5_350M
            case "gemma4-e2b":  return .gemma4E2B
            case "gemma4-e4b":  return .gemma4E4B
            default:            return .custom(modelID)
            }
        }()

        do {
            let backend = try await CoreMLLanguageModel.load(catalog) { @Sendable stage in
                print("  • \(stage)")
            }
            SystemLanguageModel.default = SystemLanguageModel(backend: backend)
        } catch {
            fail("failed to load backend: \(error)")
            exit(1)
        }

        var runner = DeepRunner()
        await runner.runAll()
        runner.summarize()
    }
}

private func readArg(after flag: String) -> String? {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        if arg == flag { return it.next() }
    }
    return nil
}
