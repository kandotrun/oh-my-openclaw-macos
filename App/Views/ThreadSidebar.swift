import SwiftUI
import OhMyOpenClawCore

struct ThreadSidebar: View {
    @Bindable var model: AppModel
    @Binding var search: String

    private var rows: [ChatSession] { ThreadList.rows(model.sessions, matching: search) }

    /// Selection follows AppModel; choosing a row asks the model to switch threads.
    private var selection: Binding<String?> {
        Binding(get: { model.selectedSession?.id }, set: { id in
            guard let id, id != model.selectedSession?.id, let session = model.sessions.first(where: { $0.id == id }) else { return }
            Task { await model.selectSession(session) }
        })
    }

    var body: some View {
        List(selection: selection) {
            if !model.sessions.isEmpty {
                Section(model.agentName) {
                    ForEach(rows) { session in
                        Label {
                            Text(session.title).lineLimit(1)
                        } icon: {
                            Image(systemName: session.isMain ? "bubble.left.and.bubble.right" : "bubble.left")
                        }
                        .tag(session.id)
                        .accessibilityIdentifier(session.isMain ? "mainThreadRow" : "threadRow")
                    }
                }
                if rows.isEmpty {
                    Text("一致するスレッドがありません").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "スレッドを検索")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.newSideChat() } } label: {
                    Label("新しいスレッド", systemImage: "square.and.pencil")
                }
                .help("新しいスレッド (⌘N)")
                .disabled(model.connectionState != .connected || model.sessions.isEmpty)
                .accessibilityIdentifier("newThreadButton")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ConnectionStatusBar(model: model) }
    }
}

/// The sidebar footer: where the app is connected, and a way to recover.
struct ConnectionStatusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if canReconnect {
                Button("再接続") { Task { await model.retryConnection() } }
                    .controlSize(.small)
                    .disabled(model.changingConnection || model.isSigningInToAccess)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
    }

    private var canReconnect: Bool {
        switch model.connectionState {
        case .failed, .pairing: true
        case .disconnected: !model.sessions.isEmpty
        case .connected, .connecting: false
        }
    }

    private var label: String {
        let target = model.isDemo ? "デモ" : model.activeGateway?.label ?? "Gateway"
        switch model.connectionState {
        case .connected: return "\(target) に接続中"
        case .connecting: return "\(target) に接続しています…"
        case .pairing: return "\(target) の承認待ち"
        case .failed: return "\(target) に接続できません"
        case .disconnected: return model.sessions.isEmpty ? "未接続" : "\(target) から切断"
        }
    }

    private var color: Color {
        switch model.connectionState {
        case .connected: .green
        case .connecting, .pairing: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}
