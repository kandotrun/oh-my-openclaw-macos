import Foundation
import OhMyOpenClawCore

struct PairingBanner: Equatable {
    let requestID: String
    let message: String
}

enum DetailContent {
    /// A pairing request must stay visible over cached threads; without threads the
    /// connection form shows the same guidance itself.
    static func pairingBanner(hasSessions: Bool, state: ConnectionState) -> PairingBanner? {
        guard hasSessions, case .pairing(let requestID, let message) = state else { return nil }
        return PairingBanner(requestID: requestID, message: message)
    }
}
