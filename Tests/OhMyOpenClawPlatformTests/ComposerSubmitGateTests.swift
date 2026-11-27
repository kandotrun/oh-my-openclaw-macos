import Testing
@testable import OhMyOpenClawPlatform

@Test func anIdleDraftTheModelAcceptsCanBeSent() {
    #expect(ComposerSubmitGate.allows(modelCanSend: true, composingOwner: nil, activeOwner: "a", pendingImports: 0))
}

/// Marked text is provisional; only a committed conversion may leave the composer.
@Test func sendingWaitsForTheInputMethodToCommit() {
    #expect(!ComposerSubmitGate.allows(modelCanSend: true, composingOwner: "a", activeOwner: "a", pendingImports: 0))
}

/// SwiftUI can drop the composition reset made while switching threads, so a stale
/// composition owned by another draft must not block this one.
@Test func aCompositionLeftInAnotherDraftDoesNotBlockThisOne() {
    #expect(ComposerSubmitGate.allows(modelCanSend: true, composingOwner: "a", activeOwner: "b", pendingImports: 0))
}

@Test func sendingWaitsForThisDraftsAttachmentsToLoad() {
    #expect(!ComposerSubmitGate.allows(modelCanSend: true, composingOwner: nil, activeOwner: "a", pendingImports: 1))
}

@Test func theModelStillDecidesWhetherSendingIsPossible() {
    #expect(!ComposerSubmitGate.allows(modelCanSend: false, composingOwner: nil, activeOwner: "a", pendingImports: 0))
}
