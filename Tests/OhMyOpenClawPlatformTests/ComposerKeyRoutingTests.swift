import Testing
@testable import OhMyOpenClawPlatform

private let returnKey: UInt16 = 36
private let keypadEnter: UInt16 = 76
private let letterA: UInt16 = 0

@Test func returnSendsAndCommandReturnAlsoSends() {
    #expect(ComposerKeyRouting.action(keyCode: returnKey, modifiers: [], hasMarkedText: false) == .send)
    #expect(ComposerKeyRouting.action(keyCode: keypadEnter, modifiers: [], hasMarkedText: false) == .send)
    #expect(ComposerKeyRouting.action(keyCode: returnKey, modifiers: [.command], hasMarkedText: false) == .send)
}

@Test func shiftOrOptionReturnInsertsANewline() {
    #expect(ComposerKeyRouting.action(keyCode: returnKey, modifiers: [.shift], hasMarkedText: false) == .insertNewline)
    #expect(ComposerKeyRouting.action(keyCode: returnKey, modifiers: [.option], hasMarkedText: false) == .insertNewline)
}

/// Committing a Japanese conversion with Return must never send the message.
@Test(arguments: [[], [.shift], [.command]] as [ComposerModifiers])
func returnDuringInputMethodCompositionPassesThrough(_ modifiers: ComposerModifiers) {
    #expect(ComposerKeyRouting.action(keyCode: returnKey, modifiers: modifiers, hasMarkedText: true) == .passThrough)
}

@Test func controlReturnAndOtherKeysPassThrough() {
    #expect(ComposerKeyRouting.action(keyCode: returnKey, modifiers: [.control], hasMarkedText: false) == .passThrough)
    #expect(ComposerKeyRouting.action(keyCode: letterA, modifiers: [], hasMarkedText: false) == .passThrough)
}
