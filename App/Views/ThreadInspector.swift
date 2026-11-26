import SwiftUI
import OhMyOpenClawCore

/// Facts about the selected thread. Project and worktree details arrive with the threads milestone.
struct ThreadInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if let session = model.selectedSession {
                Section("スレッド") {
                    LabeledContent("名前", value: session.title)
                    LabeledContent("エージェント", value: model.agentName)
                    LabeledContent("状態", value: activity)
                }
                Section("モデル") {
                    LabeledContent("モデル", value: model.models.first { $0.id == model.selectedModelID }?.name ?? model.selectedModelID ?? "既定")
                    LabeledContent("思考レベル", value: model.thinkingLevels.first { $0.id == model.selectedThinkingLevel }?.label ?? model.selectedThinkingLevel ?? "既定")
                }
                Section("識別子") {
                    identifier("キー", session.key)
                    identifier("セッション ID", session.sessionID ?? "未作成")
                }
            } else {
                Text("スレッドを選ぶと詳細を表示します。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func identifier(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        }
    }

    private var activity: String {
        switch model.activity {
        case .idle: "待機中"
        case .working: "作業中"
        case .searching: "検索中"
        case .responding: "応答中"
        case .waitingForApproval: "承認待ち"
        }
    }
}
