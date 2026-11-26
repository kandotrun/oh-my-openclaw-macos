import Foundation

/// Modifier keys that matter to the composer, independent of AppKit.
struct ComposerModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let shift = ComposerModifiers(rawValue: 1 << 0)
    static let option = ComposerModifiers(rawValue: 1 << 1)
    static let command = ComposerModifiers(rawValue: 1 << 2)
    static let control = ComposerModifiers(rawValue: 1 << 3)
}

enum ComposerKeyAction: Equatable, Sendable { case send, insertNewline, passThrough }

/// Return sends; Shift- or Option-Return inserts a newline. While the input method
/// has marked text, every key goes to it, so committing a conversion never sends.
enum ComposerKeyRouting {
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76

    static func action(keyCode: UInt16, modifiers: ComposerModifiers, hasMarkedText: Bool) -> ComposerKeyAction {
        guard !hasMarkedText, keyCode == returnKey || keyCode == keypadEnter else { return .passThrough }
        if modifiers.contains(.control) { return .passThrough }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .insertNewline }
        return .send
    }
}
