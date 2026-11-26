import Foundation

/// Commands for approving this Mac on the Gateway host. The request ID comes from
/// the Gateway and the text is meant to be pasted into a shell, so an ID is shown
/// only when it cannot carry shell syntax or be read as a CLI option.
enum PairingGuidance {
    static func commands(requestID: String) -> String {
        guard requestID.wholeMatch(of: #/[A-Za-z0-9_][A-Za-z0-9_-]{0,127}/#) != nil else { return "openclaw devices list" }
        return "openclaw devices list\nopenclaw devices approve \(requestID)"
    }
}
