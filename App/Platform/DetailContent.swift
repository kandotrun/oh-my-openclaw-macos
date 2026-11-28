import Foundation
import OhMyOpenClawCore

struct PairingBanner: Equatable {
    let requestID: String
    let message: String
}

/// A Cloudflare Access sign-in that the Gateway `target` asked for, or one under way for it.
struct AccessBanner: Equatable {
    let target: URL
    let signIn: CloudflareAccessSignInState
}

enum DetailContent {
    /// A pairing request must stay visible over cached threads; without threads the
    /// connection form shows the same guidance itself.
    static func pairingBanner(hasSessions: Bool, state: ConnectionState) -> PairingBanner? {
        guard hasSessions, case .pairing(let requestID, let message) = state else { return nil }
        return PairingBanner(requestID: requestID, message: message)
    }

    /// A sign-in asked for or under way must stay visible over cached threads, with the Gateway it
    /// is for; without threads the connection form shows the sign-in itself.
    static func accessBanner(hasSessions: Bool, signIn: CloudflareAccessSignInState) -> AccessBanner? {
        guard hasSessions, let target = signIn.target else { return nil }
        return AccessBanner(target: target, signIn: signIn)
    }
}
