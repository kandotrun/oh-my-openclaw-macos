import SwiftUI

@main
struct OhMyOpenClawApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // One main window. Closing it keeps the app and its connection running.
        Window("Oh My OpenClaw", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.restore() }
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView(model: model)
        }
    }
}
