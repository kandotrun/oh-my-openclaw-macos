import Foundation

/// A Cloudflare Access service token for a Gateway published behind Cloudflare Access.
/// Requests carry it only to the configured Gateway origin, and they never follow redirects.
public struct CloudflareAccessToken: Codable, Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init?(clientID: String, clientSecret: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isHeaderValue(id), Self.isHeaderValue(secret) else { return nil }
        self.clientID = id; self.clientSecret = secret
    }

    public func apply(to request: inout URLRequest) {
        request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }

    private static func isHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
