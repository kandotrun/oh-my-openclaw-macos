import Foundation

/// Whether the composer may send right now.
enum ComposerSubmitGate {
    /// Input-method marked text in the active draft is provisional, and attachments still
    /// loading for it would be left behind, so both wait; otherwise the model decides.
    /// A composition recorded for another draft never blocks: SwiftUI can drop the reset
    /// made while switching threads.
    static func allows(modelCanSend: Bool, composingOwner: String?, activeOwner: String, pendingImports: Int) -> Bool {
        modelCanSend && composingOwner != activeOwner && pendingImports == 0
    }
}
