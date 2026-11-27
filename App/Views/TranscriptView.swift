import SwiftUI
import OhMyOpenClawCore

/// The selected thread: messages, inline prompts, the running turn, and the composer.
/// The work log arrives in milestone 3b.
struct TranscriptView: View {
    @Bindable var model: AppModel
    @State private var loadingOlder = false
    @State private var runStartedAt: Date?
    @State private var followsBottom = true
    @State private var userScrolling = false
    @State private var nearBottom = true
    private static let bottomID = "transcriptBottom"

    var body: some View {
        VStack(spacing: 0) {
            banner
            ScrollViewReader { proxy in
            ScrollView {
                // Loaded history is paged, so measuring every row keeps bottom anchoring exact.
                VStack(alignment: .leading, spacing: 18) {
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
                        Text("このスレッドで、エージェントに作業を頼みましょう。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message, retry: { Task { await model.retryPending(message.id) } }).id(message.id)
                    }
                    ForEach(model.prompts) { prompt in
                        PromptCard(prompt: prompt) { answer in Task { await model.resolvePrompt(prompt, answer: answer) } }
                    }
                    if model.activity != .idle {
                        WorkingIndicator(activity: model.activity, since: runStartedAt ?? .now)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            // Follow new output while the reader is at the bottom; stop while they read older rows.
            .defaultScrollAnchor(followsBottom && !userScrolling ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 90
            } action: { _, value in
                nearBottom = value
                if userScrolling { followsBottom = value }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle && userScrolling { followsBottom = nearBottom }
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            // Equal-height transcripts keep their offset across a switch, so scroll explicitly.
            .task(id: model.selectedSession?.id) {
                followsBottom = true
                await Task.yield()
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            }
            ComposerView(model: model)
                .frame(maxWidth: 820)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: model.activity) { old, new in
            if new == .idle { runStartedAt = nil } else if old == .idle || runStartedAt == nil { runStartedAt = .now }
        }
        .onChange(of: model.selectedSession?.id) { _, _ in
            runStartedAt = model.activity == .idle ? nil : .now
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

/// "作業中 12 秒" for the running turn, with what the agent is doing.
private struct WorkingIndicator: View {
    let activity: ActivityState
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(label) \(max(0, Int(context.date.timeIntervalSince(since)))) 秒")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityIdentifier("workingIndicator")
    }

    private var label: String {
        switch activity {
        case .idle: ""
        case .working: "作業中"
        case .searching: "検索中"
        case .responding: "応答中"
        case .waitingForApproval: "承認待ち"
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let retry: () -> Void
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
        case .uncertain:
            Button(action: retry) { Label("送信結果を確認して再試行", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.orange)
        case .failed:
            Button(action: retry) { Label("再試行", systemImage: "exclamationmark.circle") }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.red)
        case .accepted, .complete: EmptyView()
        }
    }
}
