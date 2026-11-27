import Foundation
import OhMyOpenClawCore

/// What the connection form's two Cloudflare Access fields mean together.
enum AccessTokenEntry: Equatable {
    /// Both blank: keep the token already saved for this Gateway, if any.
    case keepSaved
    /// Both filled with values that can be sent as headers.
    case token(CloudflareAccessToken)
    /// One field blank, or a value that cannot be sent as a header.
    case incomplete

    static func parse(clientID: String, clientSecret: String) -> AccessTokenEntry {
        let blank = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(clientID) && blank(clientSecret) { return .keepSaved }
        return CloudflareAccessToken(clientID: clientID, clientSecret: clientSecret).map(AccessTokenEntry.token) ?? .incomplete
    }
}
