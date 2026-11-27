import AppKit
import Testing
@testable import OhMyOpenClawPlatform

@MainActor
private func editor(owner: String = "thread-a", text: String = "") -> (ComposerTextEditor, Recorder) {
    let editor = ComposerTextEditor(frame: .zero)
    let recorder = Recorder()
    editor.onTextChange = { recorder.changes.append($0) }
    editor.load(text, owner: owner)
    return (editor, recorder)
}

@MainActor private final class Recorder { var changes: [String] = [] }

/// A Japanese conversion started in one thread must never land in another thread's draft.
@Test @MainActor func switchingThreadsDiscardsTheCompositionWithoutWritingIt() {
    let (editor, recorder) = editor(owner: "thread-a")
    editor.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    recorder.changes.removeAll()
    editor.load("Bの下書き", owner: "thread-b")
    #expect(!editor.hasMarkedText())
    #expect(editor.string == "Bの下書き")
    #expect(recorder.changes.isEmpty)
}

/// While composing, the displayed text already belongs to the draft, so a rejected
/// send cannot restore over it and lose the composed text later.
@Test @MainActor func startingACompositionPublishesTheDisplayedText() {
    let (editor, recorder) = editor()
    editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(recorder.changes.last == "にほ")
}

/// Loading another draft must not let Undo apply the previous draft's edits.
@Test @MainActor func loadingADraftClearsUndo() {
    let (editor, _) = editor(owner: "thread-a")
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("Aの文章", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.undoManager?.endUndoGrouping()
    #expect(editor.undoManager?.canUndo == true)
    editor.load("Bの下書き", owner: "thread-b")
    #expect(editor.undoManager?.canUndo == false)
}

/// The model may refresh the same draft; an active composition keeps its text.
@Test @MainActor func refreshingTheSameDraftKeepsAnActiveComposition() {
    let (editor, _) = editor(owner: "thread-a")
    editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.load("", owner: "thread-a")
    #expect(editor.hasMarkedText())
    #expect(editor.string == "にほ")
}

/// A plain-text view rejects image-only drags unless it registers for them.
@Test @MainActor func imageOnlyDragsAreAccepted() {
    let (editor, _) = editor()
    #expect(editor.acceptableDragTypes.contains(.png))
    #expect(editor.acceptableDragTypes.contains(.tiff))
}
