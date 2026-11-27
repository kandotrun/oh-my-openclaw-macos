import Foundation

/// Whether the composer may send right now.
enum ComposerSubmitGate {
    /// Input-method marked text is provisional, and attachments still loading for this
    /// draft would be left behind, so both wait; otherwise the model decides.
    static func allows(modelCanSend: Bool, composing: Bool, pendingImports: Int) -> Bool {
        modelCanSend && !composing && pendingImports == 0
    }
}
