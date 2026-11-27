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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新しいスレッド") { Task { await delegate.model.newSideChat() } }
                    .keyboardShortcut("n")
                    .disabled(delegate.model.connectionState != .connected)
                Button("再接続") { Task { await delegate.model.retryConnection() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
