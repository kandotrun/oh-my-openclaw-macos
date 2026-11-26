import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppEnvironment.makeModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore once per launch, so reopening the window keeps the live connection.
        Task { await model.restore() }
    }

    /// The window can close while the app and its Gateway connection keep running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct OhMyOpenClawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Oh My OpenClaw", id: "main") {
            RootView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
