import Foundation

/// A person's Cloudflare Access sign-in to one Gateway, saved with the Gateway's other credentials.
/// Requests carry its application token as `Cf-Access-Token`, only to `gatewayOrigin`, never as a cookie.
public struct CloudflareAccessSession: Codable, Sendable, Equatable {
    /// The Access application token, a JWT.
    public let appToken: String
    /// `scheme://host[:port]` of the Gateway, with a lowercased host and no default port.
    public let gatewayOrigin: String
    /// The verified team domain: `<team>.cloudflareaccess.com` or `<team>.fed.cloudflareaccess.com`.
    public let authDomain: String
    /// The verified Access application audience (AUD) tag.
    public let audience: String
    /// The app token's `sub`: the person who signed in.
    public let subject: String

    /// Nil unless every field has its verified form, so a session read back from storage
    /// meets the same rules as one that has just signed in.
    public init?(appToken: String, gatewayOrigin: String, authDomain: String, audience: String, subject: String) {
        guard CloudflareAccessJWT.segments(appToken) != nil, Self.isGatewayOrigin(gatewayOrigin), Self.isTeamDomain(authDomain),
              Self.isClaimValue(audience), Self.isClaimValue(subject) else { return nil }
        self.appToken = appToken; self.gatewayOrigin = gatewayOrigin; self.authDomain = authDomain
        self.audience = audience; self.subject = subject
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let session = try Self(appToken: values.decode(String.self, forKey: .appToken),
                                     gatewayOrigin: values.decode(String.self, forKey: .gatewayOrigin),
                                     authDomain: values.decode(String.self, forKey: .authDomain),
                                     audience: values.decode(String.self, forKey: .audience),
                                     subject: values.decode(String.self, forKey: .subject)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The saved Cloudflare Access session is not valid."))
        }
        self = session
    }

    private enum CodingKeys: String, CodingKey { case appToken, gatewayOrigin, authDomain, audience, subject }

    /// The Gateway origin of a request URL: `https` for https and wss, `http` for http and ws,
    /// the lowercased host, and the port only when it is not the scheme's default.
    /// Nil for any other scheme and for a URL with user info.
    static func origin(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), parts.user == nil, parts.password == nil,
              let host = parts.encodedHost?.lowercased(), !host.isEmpty else { return nil }
        let scheme: String
        switch parts.scheme?.lowercased() {
        case "https", "wss": scheme = "https"
        case "http", "ws": scheme = "http"
        default: return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = parts.port ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }
        return scheme + "://" + host + (port == defaultPort ? "" : ":\(port)")
    }

    /// A bare, lowercased `<team>.cloudflareaccess.com` name: no scheme, port, user info or path.
    static func isTeamDomain(_ text: String) -> Bool {
        text.utf8.count <= 253 && text.wholeMatch(of: #/([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+cloudflareaccess\.com/#) != nil
    }

    private static func isGatewayOrigin(_ text: String) -> Bool {
        guard let url = URL(string: text), origin(of: url) == text else { return false }
        // Plain http stays on this Mac, as ws:// Gateway URLs do.
        return url.scheme == "https" || ["127.0.0.1", "localhost", "[::1]"].contains(URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost ?? "")
    }

    /// A non-empty claim of at most 512 bytes on one line, such as an AUD tag or a `sub`.
    static func isClaimValue(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 && text.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// The person a Cloudflare Access session signs in: their `sub` in the application `audience` of the
/// team `authDomain`. What this Mac caches for a Gateway belongs to the last person who signed in to it.
public struct CloudflareAccessAccount: Codable, Sendable, Equatable {
    public let authDomain: String
    public let audience: String
    public let subject: String
}

extension CloudflareAccessSession {
    /// The person this session signs in.
    public var account: CloudflareAccessAccount { CloudflareAccessAccount(authDomain: authDomain, audience: audience, subject: subject) }
}

extension CloudflareAccessSession: CloudflareAccessCredential {
    /// Sets `Cf-Access-Token` on a request to the Gateway origin, and nothing on any other request.
    public func apply(to request: inout URLRequest) {
        guard let url = request.url, Self.origin(of: url) == gatewayOrigin else { return }
        request.setValue(appToken, forHTTPHeaderField: "Cf-Access-Token")
    }
}

/// What a Cloudflare Access token says about itself, read without checking its signature, as
/// cloudflared does. It checks a token against the application it was issued for and shows who is
/// signed in until when; Cloudflare Access and the Gateway validate the token itself.
public struct CloudflareAccessClaims: Sendable, Equatable {
    /// `type`: `app` for an application token, `org` for a global session token.
    public let kind: String
    /// `aud`, which Access sends as a string or an array of strings.
    public let audiences: [String]
    /// `iss`: `https://<team domain>`.
    public let issuer: String
    /// `sub`: the person's ID in the Access account.
    public let subject: String
    public let email: String?
    /// `exp`.
    public let expiresAt: Date
    /// `nbf`.
    public let notBefore: Date?

    /// Nil unless the token is a compact RS256 JWS of at most 16 KiB and each claim present has its type.
    public init?(jwt: String) {
        guard let segments = CloudflareAccessJWT.segments(jwt),
              CloudflareAccessJWT.object(segments[0])?["alg"].stringValue == "RS256",
              let claims = CloudflareAccessJWT.object(segments[1]),
              let kind = claims["type"].stringValue, let issuer = claims["iss"].stringValue, let subject = claims["sub"].stringValue,
              let audiences = Self.audiences(claims["aud"]), let expiresAt = Self.date(claims["exp"]),
              let email = Self.optional(claims["email"], { $0.stringValue }), let notBefore = Self.optional(claims["nbf"], Self.date) else { return nil }
        self.kind = kind; self.audiences = audiences; self.issuer = issuer; self.subject = subject
        self.email = email; self.expiresAt = expiresAt; self.notBefore = notBefore
    }

    private static func audiences(_ claim: JSONValue) -> [String]? {
        if let audience = claim.stringValue { return [audience] }
        guard let values = claim.arrayValue else { return nil }
        let audiences = values.compactMap(\.stringValue)
        return audiences.count == values.count ? audiences : nil
    }

    private static func date(_ claim: JSONValue) -> Date? {
        claim.numberValue.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
    }

    /// `.some(nil)` for an absent or null claim, `.some(value)` for one of the right type, and nil otherwise.
    private static func optional<Value>(_ claim: JSONValue, _ read: (JSONValue) -> Value?) -> Value?? {
        if claim == .null { return .some(nil) }
        return read(claim).map { .some($0) }
    }
}

/// Compact JWS strings as Cloudflare Access issues them.
enum CloudflareAccessJWT {
    static let maxBytes = 16 * 1024

    /// The header, payload and signature segments, or nil unless the token is three non-empty
    /// base64url segments of at most 16 KiB in total.
    static func segments(_ token: String) -> [Substring]? {
        guard token.utf8.count <= maxBytes else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isBase64URL) }) else { return nil }
        return segments
    }

    /// The JSON object a segment encodes.
    static func object(_ segment: Substring) -> JSONValue? {
        guard let data = Data(base64URL: String(segment)), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value.objectValue != nil else { return nil }
        return value
    }

    static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"): true
        default: false
        }
    }
}
