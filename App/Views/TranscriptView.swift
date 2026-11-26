import SwiftUI
import OhMyOpenClawCore

/// Read-only transcript for the app shell; the work log and composer replace it in the next milestone.
struct TranscriptView: View {
    @Bindable var model: AppModel
    @State private var loadingOlder = false

    var body: some View {
        VStack(spacing: 0) {
            banner
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.hasMoreHistory {
                        Button {
                            loadingOlder = true
                            Task { await model.loadOlderHistory(); loadingOlder = false }
                        } label: {
                            HStack(spacing: 6) {
                                if loadingOlder { ProgressView().controlSize(.small) }
                                Text("以前のメッセージを読み込む")
                            }
                        }
                        .buttonStyle(.link)
                        .disabled(loadingOlder || model.connectionState != .connected || model.changingConnection)
                        .frame(maxWidth: .infinity)
                    }
                    if model.messages.isEmpty {
                        Text("まだメッセージはありません。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let text = model.errorMessage ?? model.notice, !text.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: model.errorMessage != nil ? "exclamationmark.triangle" : "info.circle")
                Text(text).lineLimit(3)
                Spacer()
                Button("閉じる") { model.errorMessage = nil; model.notice = nil }.buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !message.text.isEmpty {
                    if isUser {
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        MarkdownMessageView(text: message.text)
                    }
                }
                ForEach(message.attachments) { attachment in
                    Label(attachment.fileName, systemImage: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if isUser { delivery }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var delivery: some View {
        switch message.delivery {
        case .pending: Label("送信中", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .uncertain: Label("送信結果を確認できませんでした", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
        case .failed: Label("送信できませんでした", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        case .accepted, .complete: EmptyView()
        }
    }
}
