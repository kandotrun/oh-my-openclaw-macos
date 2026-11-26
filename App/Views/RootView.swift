import SwiftUI
import OhMyOpenClawCore

struct RootView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            ThreadSidebar(model: model, search: $search)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if model.sessions.isEmpty { ConnectionView(model: model) }
                else { TranscriptView(model: model) }
            }
            .navigationTitle(model.sessions.isEmpty ? "Oh My OpenClaw" : model.selectedSession?.title ?? "Oh My OpenClaw")
            .navigationSubtitle(model.sessions.isEmpty ? "" : model.isDemo ? "デモ" : model.activeGateway?.label ?? "")
        }
        .inspector(isPresented: $showInspector) {
            ThreadInspector(model: model)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label(showInspector ? "インスペクターを隠す" : "インスペクターを表示", systemImage: "sidebar.right")
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .help("インスペクター (⌥⌘B)")
            }
        }
    }
}
