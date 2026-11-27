import AppKit

/// The composer's AppKit editor.
/// - Return goes through `ComposerKeyRouting`.
/// - Pasted or dropped files and images become attachments.
/// - Each draft owner keeps its own text, composition, and undo history.
final class ComposerTextEditor: NSTextView {
    var onSend: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImageData: ((Data, String) -> Void)?
    var onCompositionChange: ((Bool) -> Void)?
    /// The visible text changed while showing `ownerID`'s draft.
    var onTextChange: ((String) -> Void)?

    private(set) var ownerID: String?
    private var loading = false
    private let draftUndoManager = UndoManager()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        textContainerInset = NSSize(width: 0, height: 3)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        setAccessibilityIdentifier("composerText")
        updateDragTypeRegistration()
    }

    /// Undo belongs to the draft, not the window, so loading another draft can clear it.
    override var undoManager: UndoManager? { draftUndoManager }

    /// Shows a draft. A new owner first discards any composition and undo history, so
    /// neither can reach its draft. The same owner keeps an active composition.
    func load(_ text: String, owner: String) {
        if owner != ownerID {
            loading = true
            if hasMarkedText() {
                inputContext?.discardMarkedText()
                unmarkText()
            }
            string = text
            draftUndoManager.removeAllActions()
            ownerID = owner
            loading = false
            onCompositionChange?(false)
        } else if string != text, !hasMarkedText() {
            loading = true
            string = text
            draftUndoManager.removeAllActions()
            loading = false
        }
    }

    /// Called by the text delegate after user edits.
    func publishTextChange() {
        guard !loading else { return }
        onTextChange?(string)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?(hasMarkedText())
        // The composing text already belongs to the draft, so a rejected send cannot
        // restore over it and lose the composed text later.
        publishTextChange()
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

    // A plain-text view only accepts text and file drags by default.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.png, .tiff] }

    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        type == .png || type == .tiff ? .copy : super.dragOperation(for: dragInfo, type: type)
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
