import Testing
@testable import OhMyOpenClawPlatform

@Test func anIdleDraftTheModelAcceptsCanBeSent() {
    #expect(ComposerSubmitGate.allows(modelCanSend: true, composing: false, pendingImports: 0))
}

/// Marked text is provisional; only a committed conversion may leave the composer.
@Test func sendingWaitsForTheInputMethodToCommit() {
    #expect(!ComposerSubmitGate.allows(modelCanSend: true, composing: true, pendingImports: 0))
}

@Test func sendingWaitsForThisDraftsAttachmentsToLoad() {
    #expect(!ComposerSubmitGate.allows(modelCanSend: true, composing: false, pendingImports: 1))
}

@Test func theModelStillDecidesWhetherSendingIsPossible() {
    #expect(!ComposerSubmitGate.allows(modelCanSend: false, composing: false, pendingImports: 0))
}
