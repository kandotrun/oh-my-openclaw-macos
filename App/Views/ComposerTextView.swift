import AppKit
import SwiftUI

/// Routes Return through `ComposerKeyRouting` and turns pasted or dropped files and
/// images into attachments instead of inserting their paths.
final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImageData: ((Data, String) -> Void)?
    var onCompositionChange: ((Bool) -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?(hasMarkedText())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onCompositionChange?(hasMarkedText())
    }

    override func keyDown(with event: NSEvent) {
        let action = ComposerKeyRouting.action(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags), hasMarkedText: hasMarkedText())
        switch action {
        case .send: onSend?()
        case .insertNewline: insertNewlineIgnoringFieldEditor(nil)
        case .passThrough: super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func paste(_ sender: Any?) {
        if attach(from: NSPasteboard.general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if attach(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func attach(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onAttachFiles?(urls)
            return true
        }
        if let png = pasteboard.data(forType: .png) { onAttachImageData?(png, "Pasted.png"); return true }
        if let tiff = pasteboard.data(forType: .tiff) { onAttachImageData?(tiff, "Pasted.tiff"); return true }
        return false
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ComposerModifiers {
        var result: ComposerModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

/// A plain-text editor that grows from one to eight lines.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEditable: Bool
    var onSend: () -> Void
    var onAttachFiles: ([URL]) -> Void
    var onAttachImageData: (Data, String) -> Void
    var onCompositionChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = ComposerNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("composerText")
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        wire(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        wire(textView)
        textView.isEditable = isEditable
        // Never replace the text while the input method is composing.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        context.coordinator.updateHeight()
    }

    private func wire(_ textView: ComposerNSTextView) {
        textView.onSend = onSend
        textView.onAttachFiles = onAttachFiles
        textView.onAttachImageData = onAttachImageData
        textView.onCompositionChange = onCompositionChange
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let inset = textView.textContainerInset.height * 2
            let line = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let target = min(max(layout.usedRect(for: container).height, line), line * 8) + inset
            guard abs(parent.height - target) > 0.5 else { return }
            let binding = parent.$height
            Task { @MainActor in binding.wrappedValue = target }
        }
    }
}
