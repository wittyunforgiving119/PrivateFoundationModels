import SwiftUI

/// Chat app that lets you flip between Apple's `FoundationModels`
/// framework (iOS 26+) and any model the `PrivateFoundationModels` CoreML
/// backend can load — using exactly the same `LanguageModelSession.respond`
/// call site.
///
/// Memory contract:
///
///   - Only ONE backend is resident at a time. Switching releases the
///     previous backend first, then loads the new one. See
///     `ModelManager.switchTo(_:)`.
///   - Resident-set size is sampled live via `mach_task_basic_info` and
///     displayed at the top of the chat. Use it to confirm the previous
///     model actually unloaded before the new one starts paging in.
///   - On `UIApplication.didReceiveMemoryWarningNotification`, the
///     manager aggressively releases the current backend to keep the app
///     from being killed.
@main
struct PFMSwitcherApp: App {
    @StateObject private var manager = ModelManager()

    var body: some Scene {
        WindowGroup {
            ChatView(manager: manager)
        }
    }
}
