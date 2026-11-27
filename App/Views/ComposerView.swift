import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OhMyOpenClawCore

/// Message input with attachments, the model menu, and send or stop.
struct ComposerView: View {
    @Bindable var model: AppModel
    @State private var height: CGFloat = 24
    @State private var choosingFiles = false
    @State private var inputError: String?
    /// The draft whose input-method text is still marked, if any.
    @State private var composingOwner: String?
    /// Imports in progress per draft owner, so another thread's import never blocks this one.
    @State private var pendingImports: [String: Int] = [:]

    private var isRunning: Bool { model.activity != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty { AttachmentTray(model: model) }
            ZStack(alignment: .topLeading) {
                // Input-method marked text is not in the draft yet; keep the placeholder out of its way.
                if model.draftText.isEmpty && composingOwner != model.composerContextID {
                    Text("メッセージを入力（Return で送信、Shift-Return で改行）")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: model.draftText, ownerID: model.composerContextID, height: $height,
                                 isEditable: model.selectedSession != nil,
                                 onTextChange: { value, owner in
                                     // Edits made for a draft that is no longer selected are dropped.
                                     guard owner == model.composerContextID else { return }
                                     model.draftText = value
                                 },
                                 onSend: send, onAttachFiles: attachFiles, onAttachImageData: attachImage,
                                 onCompositionChange: { composing, owner in
                                     if composing { composingOwner = owner } else if composingOwner == owner { composingOwner = nil }
                                 })
                    .frame(height: height)
            }
            HStack(spacing: 10) {
                Button { choosingFiles = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("ファイルを添付")
                    .accessibilityIdentifier("attachButton")
                ModelMenu(model: model).disabled(isRunning)
                if let inputError {
                    Text(inputError).font(.caption).foregroundStyle(.red).lineLimit(1)
                    Button { self.inputError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                Spacer()
                if pendingImports[model.composerContextID, default: 0] > 0 { ProgressView().controlSize(.small).help("添付を読み込んでいます") }
                if isRunning {
                    Button { Task { await model.stop() } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("応答を停止 (⌘.)")
                    .accessibilityIdentifier("stopButton")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(canSubmit ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .help("送信 (Return)")
                    .accessibilityIdentifier("sendButton")
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): attachFiles(urls)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { inputError = error.localizedDescription }
            }
        }
    }

    private var canSubmit: Bool {
        ComposerSubmitGate.allows(modelCanSend: model.canSend, composingOwner: composingOwner, activeOwner: model.composerContextID,
                                  pendingImports: pendingImports[model.composerContextID, default: 0])
    }

    private func send() {
        guard canSubmit else { return }
        Task { await model.send() }
    }

    private var imageLimit: Int { model.imageAttachmentLimit ?? AttachmentImport.imageLimit }

    private func attachFiles(_ urls: [URL]) {
        let context = model.composerContextID
        let limit = imageLimit
        pendingImports[context, default: 0] += 1
        Task {
            defer { pendingImports[context, default: 1] -= 1 }
            for url in urls {
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) { try AttachmentImport.file(url: url, imageLimit: limit) }.value
                    guard model.composerContextID == context else { inputError = "スレッドが切り替わったため、添付を中断しました。"; return }
                    model.addAttachment(data: loaded.data, fileName: loaded.fileName, mimeType: loaded.mimeType)
                } catch { inputError = error.localizedDescription }
            }
        }
    }

    private func attachImage(_ data: Data, _ fileName: String) {
        let context = model.composerContextID
        let limit = imageLimit
        pendingImports[context, default: 0] += 1
        Task {
            defer { pendingImports[context, default: 1] -= 1 }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try AttachmentImport.image(data: data, fileName: fileName, limit: limit) }.value
                guard model.composerContextID == context else { return }
                model.addAttachment(data: loaded.data, fileName: loaded.fileName, mimeType: loaded.mimeType)
            } catch { inputError = error.localizedDescription }
        }
    }
}

/// One menu for the model and thinking level, shown as "<model> <level>".
private struct ModelMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Section("モデル") {
                Button("Gateway の既定") { Task { await model.setModel(nil) } }
                ForEach(model.models) { option in
                    Button { Task { await model.setModel(option.id) } } label: {
                        if option.id == model.selectedModelID { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                    }
                }
            }
            if !model.thinkingLevels.isEmpty {
                Section("思考レベル") {
                    Button("既定") { Task { await model.setThinking(nil) } }
                    ForEach(model.thinkingLevels) { level in
                        Button { Task { await model.setThinking(level.id) } } label: {
                            if level.id == model.selectedThinkingLevel { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                        }
                    }
                }
            }
        } label: {
            Text(label).font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("モデルと思考レベル")
        .accessibilityIdentifier("modelMenu")
    }

    private var label: String {
        let name = model.models.first { $0.id == model.selectedModelID }?.name ?? "既定のモデル"
        guard let level = model.thinkingLevels.first(where: { $0.id == model.selectedThinkingLevel })?.label else { return name }
        return "\(name) \(level)"
    }
}

private struct AttachmentTray: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.mimeType.hasPrefix("image/"), let image = NSImage(data: attachment.data) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                        }
                        Text(attachment.fileName).font(.caption).lineLimit(1).frame(maxWidth: 160)
                        Button { model.removeAttachment(attachment.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(attachment.fileName)を取り除く")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
