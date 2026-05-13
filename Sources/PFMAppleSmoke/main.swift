// pfm-apple-smoke — minimal end-to-end check for the Apple
// FoundationModels passthrough backend. Loads Apple's native model
// (no download — the model is built into the OS) and runs both
// respond(to:) and streamResponse(to:) through PFM's call sites.
//
//   swift run -c release pfm-apple-smoke
//
// Requires iOS 26+ / macOS 26+ / visionOS 26+ with Apple Intelligence
// enabled. Exits non-zero with a clear message otherwise.

import Foundation
import PrivateFoundationModels
import PrivateFoundationModelsApple

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

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
func run() async {
    let availability = AppleFoundationModel.availability
    banner("PrivateFoundationModelsApple — Apple FM passthrough smoke test")
    info("availability: \(availability)")

    switch availability {
    case .available:
        break
    case .unavailable(let reason):
        fail("Apple FoundationModels is not available on this device/account: \(reason)")
        fail("Enable Apple Intelligence in System Settings and try again.")
        exit(2)
    }

    let backend = AppleFoundationModel.load()
    SystemLanguageModel.default = SystemLanguageModel(backend: backend)

    let prompt = "In one short sentence, what is the capital of France?"
    let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: 60)

    do {
        banner("1. respond(to:)")
        let session = LanguageModelSession(instructions: Instructions("Be brief."))
        let start = ContinuousClock.now
        let response = try await session.respond(to: prompt, options: options)
        ok("respond() returned in \(ms(ContinuousClock.now - start))")
        print("\n--- response ---\n\(response.content)\n----------------")
    } catch {
        fail("respond failed: \(error)")
        exit(3)
    }

    do {
        banner("2. streamResponse(to:)")
        let session = LanguageModelSession(instructions: Instructions("Be brief."))
        let stream = session.streamResponse(to: prompt, options: options)
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
        exit(4)
    }

    struct Address: Generable, Equatable, CustomStringConvertible {
        let city: String
        let country: String
        static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: "object",
                properties: [
                    "city":    .init(type: "string"),
                    "country": .init(type: "string"),
                ],
                required: ["city", "country"]
            )
        }
        var description: String { "\(city), \(country)" }
    }

    do {
        banner("3. respond(to: generating:) — Generable cross-translation")
        let session = LanguageModelSession(
            instructions: Instructions("Return strict JSON for a famous landmark.")
        )
        let start = ContinuousClock.now
        let response = try await session.respond(
            to: "Pick one famous landmark and return its city and country.",
            generating: Address.self,
            options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 120)
        )
        ok("generating: Address.self → \(response.content) (\(ms(ContinuousClock.now - start)))")
    } catch {
        fail("Generable failed: \(error)")
        exit(5)
    }

    banner("All smoke checks passed against Apple's native FoundationModels.")
}

if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
    await run()
} else {
    fail("This binary requires macOS 26.0 / iOS 26.0 / visionOS 26.0 or newer.")
    exit(1)
}
