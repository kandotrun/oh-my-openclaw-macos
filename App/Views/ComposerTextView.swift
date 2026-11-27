import AppKit
import SwiftUI

/// Hosts `ComposerTextEditor`, growing from one to eight lines. Edits are reported with
/// the draft owner they were made for, so a write can never land in another thread.
struct ComposerTextView: NSViewRepresentable {
    var text: String
    var ownerID: String
    @Binding var height: CGFloat
    var isEditable: Bool
    var onTextChange: (_ text: String, _ owner: String) -> Void
    var onSend: () -> Void
    var onAttachFiles: ([URL]) -> Void
    var onAttachImageData: (Data, String) -> Void
    var onCompositionChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let editor = ComposerTextEditor(frame: .zero)
        editor.delegate = context.coordinator
        scrollView.documentView = editor
        context.coordinator.editor = editor
        wire(editor, context.coordinator)
        editor.load(text, owner: ownerID)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? ComposerTextEditor else { return }
        wire(editor, context.coordinator)
        editor.isEditable = isEditable
        editor.load(text, owner: ownerID)
        context.coordinator.updateHeight()
    }

    private func wire(_ editor: ComposerTextEditor, _ coordinator: Coordinator) {
        editor.onSend = onSend
        editor.onAttachFiles = onAttachFiles
        editor.onAttachImageData = onAttachImageData
        editor.onCompositionChange = onCompositionChange
        editor.onTextChange = { [weak editor, weak coordinator] value in
            guard let owner = editor?.ownerID else { return }
            coordinator?.parent.onTextChange(value, owner)
            coordinator?.updateHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var editor: ComposerTextEditor?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) { editor?.publishTextChange() }

        func updateHeight() {
            guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let inset = editor.textContainerInset.height * 2
            let line = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let target = min(max(layout.usedRect(for: container).height, line), line * 8) + inset
            guard abs(parent.height - target) > 0.5 else { return }
            let binding = parent.$height
            Task { @MainActor in binding.wrappedValue = target }
        }
    }
}
