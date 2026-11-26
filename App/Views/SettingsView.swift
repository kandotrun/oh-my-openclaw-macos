import SwiftUI
import OhMyOpenClawCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GatewaySettings(model: model)
                .tabItem { Label("Gateway", systemImage: "network") }
            AboutSettings()
                .tabItem { Label("このアプリ", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct GatewaySettings: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var renaming: SavedGateway?
    @State private var renameText = ""
    @State private var deleting: SavedGateway?
    @State private var deletionError: String?

    private var busy: Bool { model.changingConnection || model.connectionState == .connecting }

    var body: some View {
        Form {
            Section("接続") {
                LabeledContent("状態", value: status)
                HStack {
                    Button("再接続") { Task { await model.retryConnection() } }
                        .disabled(busy || (model.activeGateway == nil && !model.isDemo))
                    Button("接続を切る", role: .destructive) { Task { await model.disconnect() } }
                        .disabled(model.changingConnection || model.connectionState == .disconnected)
                }
                // Failures from switching, renaming, or saving Gateways must be visible here too.
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settingsError")
                }
            }
            Section("保存済みの Gateway") {
                if model.savedGateways.isEmpty {
                    Text("まだ保存された Gateway はありません。").foregroundStyle(.secondary)
                }
                ForEach(model.savedGateways) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: model.activeGateway?.id == profile.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.activeGateway?.id == profile.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.label)
                            Text(profile.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("切り替え") { Task { await model.switchGateway(profile) } }
                            .disabled(busy || model.activeGateway?.id == profile.id)
                        Menu {
                            Button("名前を変更") { renameText = profile.alias ?? ""; renaming = profile }
                            Button("削除", role: .destructive) { deletionError = nil; deleting = profile }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Button("Gateway を追加…") { adding = true }.disabled(busy)
                if let deletionError { Text(deletionError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) {
            VStack(spacing: 0) {
                ConnectionView(model: model)
                Divider()
                HStack { Spacer(); Button("閉じる") { adding = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .frame(width: 560, height: 560)
            .onChange(of: model.connectionState) { _, state in if state == .connected { adding = false } }
        }
        .alert("Gateway の名前", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("ホスト名を使う", text: $renameText)
            Button("保存") { if let renaming { model.renameGateway(renaming, alias: renameText) }; renaming = nil }
            Button("キャンセル", role: .cancel) { renaming = nil }
        } message: { Text("この Mac で表示する名前です。空欄にするとホスト名を使います。") }
        .alert("Gateway を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { profile in
            Button("削除", role: .destructive) {
                Task {
                    if !(await model.deleteGateway(profile)) { deletionError = model.notice ?? "Gateway を削除できませんでした。もう一度お試しください。" }
                    deleting = nil
                }
            }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: { profile in
            Text("「\(profile.label)」の接続先と認証情報をこの Mac から削除します。")
        }
    }

    private var status: String {
        let target = model.isDemo ? "デモ" : model.activeGateway?.label ?? "Gateway"
        switch model.connectionState {
        case .connected: return "\(target) に接続中"
        case .connecting: return "接続しています…"
        case .pairing: return "\(target) の承認待ち"
        case .failed(let message): return message
        case .disconnected: return "未接続"
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            LabeledContent("バージョン", value: version)
            Text("自分の OpenClaw Gateway で、エージェントに開発を任せるための独立したクライアントです。AI サービスや Gateway の管理機能は含みません。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
