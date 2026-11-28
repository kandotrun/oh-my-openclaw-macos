import CryptoKit
import Foundation
import Security

/// Where the browser sign-in finds the Cloudflare Access relay and a team's keys.
public struct CloudflareAccessEndpoints: Sendable, Equatable {
    /// The relay that hands the browser's sign-in to this app, with a trailing slash.
    public var relay = URL(string: "https://login.cloudflareaccess.org/")!
    /// The relay for FedRAMP team domains, `*.fed.cloudflareaccess.com`.
    public var fedRelay = URL(string: "https://login.fed.cloudflareaccess.org/")!
    /// Tests only: the origin that stands in for `https://<team domain>` when fetching keys.
    public var teamDomainOrigin: URL?

    public static let cloudflare = CloudflareAccessEndpoints()

    /// A loopback test fixture that plays both relays and the team domain, or nil unless `origin` is
    /// plain http on 127.0.0.1, localhost or [::1] with nothing after the port.
    public static func loopbackFixture(_ origin: URL) -> CloudflareAccessEndpoints? {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false), parts.scheme == "http",
              let host = parts.encodedHost, ["127.0.0.1", "localhost", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.percentEncodedPath) else { return nil }
        var root = parts, bare = parts
        root.percentEncodedPath = "/"
        bare.percentEncodedPath = ""
        guard let relay = root.url, let teamDomain = bare.url else { return nil }
        return CloudflareAccessEndpoints(relay: relay, fedRelay: relay, teamDomainOrigin: teamDomain)
    }
}

/// The Cloudflare Access application in front of a Gateway, as its verified metadata names it.
public struct CloudflareAccessApplication: Sendable, Equatable {
    /// The Gateway endpoint over https, or over http on loopback: what the browser signs in to.
    public let url: URL
    /// The verified team domain, `<team>.cloudflareaccess.com` or `<team>.fed.cloudflareaccess.com`.
    public let authDomain: String
    /// The verified application audience (AUD) tag.
    public let audience: String
}

/// The key pair of one sign-in attempt. The relay seals the tokens to its public key, which the
/// browser link names as well. It stays in memory and is never reused.
public struct CloudflareAccessTransferKey: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }
    /// Tests only: a published key, for fixed vectors.
    init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    /// The public key in padded base64url, 44 characters, as cloudflared sends it.
    public var publicKey: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}

/// Signs a person in to the Cloudflare Access application in front of a Gateway through the system
/// browser, as `cloudflared access login` does (cloudflared token/token.go and token/transfer.go at
/// ead8b81): verify the application's signed metadata, open the browser at the sign-in link, then
/// wait for the relay to hand over the application token, sealed to this attempt's key.
public enum CloudflareAccessSignIn {
    /// Sends one request without following redirects or storing cookies, and returns the answer with
    /// at most `maxBytes + 1` bytes of its body, so that callers can tell a body that is too long.
    public typealias Fetch = @Sendable (URLRequest, _ maxBytes: Int) async throws -> (Data, HTTPURLResponse)
    /// Waits between polls of the relay.
    public typealias Pause = @Sendable (Duration) async throws -> Void

    static let metadataTimeout: TimeInterval = 7
    static let keysTimeout: TimeInterval = 10
    static let maxKeysBytes = 1 << 20
    /// cloudflared waits 60 s for each long poll.
    static let pollTimeout: TimeInterval = 65
    static let maxTransferBytes = 64 << 10

    /// Transport errors the network recovers from, such as a Wi-Fi or VPN change during the browser
    /// sign-in. A long poll that times out has only found the browser not done yet. A DNS lookup
    /// that fails while the network changes usually surfaces as `cannotFindHost`.
    private static let briefNetworkErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                                                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
    private static let asciiWhitespace: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D, 0x20]

    /// The sign-in's failures. Each message is constant: none carries a URL, a header or a token.
    enum Failure: String, CaseIterable {
        case notProtected = "ACCESS_NOT_PROTECTED"
        case unreachable = "ACCESS_UNREACHABLE"
        case metadataInvalid = "ACCESS_METADATA_INVALID"
        case transferFailed = "ACCESS_TRANSFER_FAILED"
        case timedOut = "ACCESS_SIGN_IN_TIMEOUT"
        case tokenInvalid = "ACCESS_TOKEN_INVALID"

        var error: GatewayFailure { GatewayFailure(code: rawValue, message: message) }

        private var message: String {
            switch self {
            case .notProtected: "この URL では Cloudflare Access のアプリを確認できませんでした。URL と、Gateway が Cloudflare Access で保護されているかを確認してください。"
            case .unreachable: "Cloudflare Access に接続できませんでした。ネットワークを確認して、もう一度お試しください。"
            case .metadataInvalid: "Cloudflare Access の応答を検証できなかったため、サインインを中止しました。URL を確認してください。"
            case .transferFailed: "Cloudflare Access からサインイン情報を受け取れませんでした。もう一度サインインしてください。"
            case .timedOut: "5 分以内にサインインが完了しませんでした。もう一度サインインしてください。"
            case .tokenInvalid: "受け取ったサインイン情報がこの Gateway のものではないか、有効期限が切れています。もう一度サインインしてください。"
            }
        }
    }

    // MARK: Transport

    /// URLSession with no cookie store, credentials or cache, and no redirects; its default User-Agent.
    public static let liveFetch: Fetch = { request, maxBytes in
        let http = CloudflareAccessSignIn.liveSession(timeout: request.timeoutInterval)
        defer { http.invalidateAndCancel() }
        let (bytes, response) = try await http.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (try await CloudflareAccessSignIn.readBody(bytes, maxBytes: maxBytes), response)
    }

    public static let livePause: Pause = { try await Task.sleep(for: $0) }

    static func liveSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration, delegate: InboundMediaRedirectRefusal(), delegateQueue: nil)
    }

    /// A body up to one byte past `maxBytes`.
    static func readBody<Bytes: AsyncSequence>(_ bytes: Bytes, maxBytes: Int) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { break }
        }
        return data
    }

    // MARK: Step 1: the application

    /// The Access application a Gateway endpoint is: the same host, port and path over https, or over
    /// http for a loopback endpoint.
    public static func applicationURL(for endpoint: URL) throws -> URL {
        let validated = try GatewayEndpoint.parse(endpoint.absoluteString)
        guard var parts = URLComponents(url: validated, resolvingAgainstBaseURL: false) else { throw Failure.notProtected.error }
        parts.scheme = parts.scheme == "wss" ? "https" : "http"
        guard let url = parts.url else { throw Failure.notProtected.error }
        return url
    }

    /// The verified Access application in front of `endpoint`. A HEAD asks the Access edge for the
    /// application's signed metadata; nothing it says is trusted until the named team's key verifies
    /// it and its claims name this Gateway's host as of `now`. The signed host is what binds the
    /// application, and so the token the browser issues, to the origin that will receive the token.
    public static func discover(_ endpoint: URL, endpoints: CloudflareAccessEndpoints = .cloudflare, now: Date,
                                fetch: Fetch = liveFetch) async throws -> CloudflareAccessApplication {
        let url = try applicationURL(for: endpoint)
        var probe = URLRequest(url: url)
        probe.httpMethod = "HEAD"
        probe.setValue("true", forHTTPHeaderField: "Cf-Access-Metadata-Request")
        probe.timeoutInterval = metadataTimeout
        // The status does not matter: Access answers a plain request with its login redirect.
        let (_, answer) = try await send(probe, maxBytes: 0, fetch: fetch)
        guard let jws = answer.value(forHTTPHeaderField: "Cf-Access-Metadata"), !jws.isEmpty else { throw Failure.notProtected.error }
        let metadata = try SignedMetadata(jws)
        guard let keysURL = keysURL(teamDomain: metadata.teamDomain, endpoints: endpoints) else { throw Failure.metadataInvalid.error }
        var keysRequest = URLRequest(url: keysURL)
        keysRequest.timeoutInterval = keysTimeout
        let (keys, keysAnswer) = try await send(keysRequest, maxBytes: maxKeysBytes, fetch: fetch)
        guard keysAnswer.statusCode == 200, keys.count <= maxKeysBytes else { throw Failure.metadataInvalid.error }
        let audience = try metadata.verifiedAudience(keys: keys, host: url.host() ?? "", now: now)
        return CloudflareAccessApplication(url: url, authDomain: metadata.teamDomain, audience: audience)
    }

    /// A discovery request; when it fails in transit, Access is unreachable.
    private static func send(_ request: URLRequest, maxBytes: Int, fetch: Fetch) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do { result = try await fetch(request, maxBytes) } catch {
            try Task.checkCancellation()
            throw Failure.unreachable.error
        }
        try Task.checkCancellation()
        return result
    }

    /// `https://<team domain>/cdn-cgi/access/certs`, or the same path on the test origin.
    private static func keysURL(teamDomain: String, endpoints: CloudflareAccessEndpoints) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = teamDomain
        if let origin = endpoints.teamDomainOrigin.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            parts.scheme = origin.scheme
            parts.encodedHost = origin.encodedHost
            parts.port = origin.port
        }
        parts.path = "/cdn-cgi/access/certs"
        return parts.url
    }

    // MARK: Step 2: the browser link

    /// The link that signs the person in to `app` in the browser, built as cloudflared's
    /// `buildRequestURL` builds it. Afterwards the relay holds the tokens for the holder of `key`.
    public static func signInURL(_ app: CloudflareAccessApplication, key: CloudflareAccessTransferKey) throws -> URL {
        try signInURL(app, key: key, closeInterstitial: true)
    }

    static func signInURL(_ app: CloudflareAccessApplication, key: CloudflareAccessTransferKey, closeInterstitial: Bool) throws -> URL {
        let token = key.publicKey
        // send_org_token also issues the global-session token; awaitSession leaves it unread.
        var query = [("aud", app.audience), ("token", token),
                     ("redirect_url", app.url.absoluteString + "?" + formEncode([("aud", app.audience), ("token", token)])),
                     ("send_org_token", "true"), ("edge_token_transfer", "true")]
        if closeInterstitial { query.append(("close_interstitial", "true")) }
        guard var parts = URLComponents(url: app.url, resolvingAgainstBaseURL: false) else { throw Failure.notProtected.error }
        parts.percentEncodedPath = "/cdn-cgi/access/cli"
        parts.percentEncodedQuery = formEncode(query)
        guard let url = parts.url else { throw Failure.notProtected.error }
        return url
    }

    /// Go's `url.Values.Encode`: keys sorted, spaces as `+`, and every other byte but
    /// `A-Z a-z 0-9 - . _ ~` percent-encoded.
    static func formEncode(_ items: [(String, String)]) -> String {
        items.sorted { $0.0 < $1.0 }.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    private static func escape(_ text: String) -> String {
        var escaped = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                escaped.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "): escaped += "+"
            default: escaped += String(format: "%%%02X", byte)
            }
        }
        return escaped
    }

    // MARK: Steps 3 and 4: the relay

    /// Waits until `deadline` for the browser sign-in at `signInURL(app, key:)` to finish, long-polling
    /// the relay with nothing but the public key, and returns the person's session for the Gateway.
    ///
    /// - The relay answering 200 with a body ends the wait: the sealed application token must open
    ///   with `key` and be for `app`. The org token beside it is never read.
    /// - A 401, a 403 or a server error from the relay ends the sign-in.
    /// - Any other answer means the browser is not done yet: poll again after a second.
    /// - A brief network failure, such as a timed-out poll or a lost connection, backs off for one
    ///   second, then two, and polls again. Any other transport failure ends the sign-in.
    public static func awaitSession(_ app: CloudflareAccessApplication, key: CloudflareAccessTransferKey,
                                    endpoints: CloudflareAccessEndpoints = .cloudflare, deadline: Date,
                                    now: @Sendable () -> Date = { Date() }, pause: Pause = livePause,
                                    fetch: Fetch = liveFetch) async throws -> CloudflareAccessSession {
        let relay = app.authDomain.hasSuffix(".fed.cloudflareaccess.com") ? endpoints.fedRelay : endpoints.relay
        // The padding `=` stays literal in the path, as cloudflared sends it.
        guard let url = URL(string: relay.absoluteString + "transfer/" + key.publicKey) else { throw Failure.transferFailed.error }
        var failuresInARow = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { throw Failure.timedOut.error }
            var request = URLRequest(url: url)
            request.timeoutInterval = min(pollTimeout, max(1, remaining))
            let data: Data, answer: HTTPURLResponse
            do { (data, answer) = try await fetch(request, maxTransferBytes) } catch {
                try Task.checkCancellation()
                guard let code = (error as? URLError)?.code, briefNetworkErrors.contains(code) else { throw Failure.transferFailed.error }
                failuresInARow += 1
                try await pause(.seconds(failuresInARow == 1 ? 1 : 2))
                continue
            }
            try Task.checkCancellation()
            failuresInARow = 0
            switch answer.statusCode {
            case 200 where !data.isEmpty:
                guard data.count <= maxTransferBytes else { throw Failure.transferFailed.error }
                let appToken = try openTransfer(body: data, senderKey: answer.value(forHTTPHeaderField: "service-public-key"), key: key)
                return try validatedSession(appToken: appToken, for: app, now: now())
            case 401, 403, 500...:
                throw Failure.transferFailed.error
            default:
                try await pause(.seconds(1))
            }
        }
    }

    /// The application token in a relay answer: standard base64 of `nonce ‖ tag ‖ ciphertext`,
    /// sealed to `key` by the relay key that `service-public-key` names.
    static func openTransfer(body: Data, senderKey: String?, key: CloudflareAccessTransferKey) throws -> String {
        guard let sealed = Data(base64Encoded: body.filter { !asciiWhitespace.contains($0) }), let sender = relayKey(senderKey),
              let plaintext = try? NaClBox.open(noncePrefixed: sealed, from: sender, using: key.privateKey),
              let transfer = try? JSONDecoder().decode(Transfer.self, from: plaintext) else { throw Failure.transferFailed.error }
        return transfer.appToken
    }

    /// The relay's JSON. Only the application token is decoded: the org token, which signs in to
    /// every application of the team, is decrypted with it and dropped unread.
    private struct Transfer: Decodable {
        let appToken: String
        private enum CodingKeys: String, CodingKey { case appToken = "app_token" }
    }

    /// The relay's key: exactly 32 bytes in base64url, with or without its one padding character.
    private static func relayKey(_ text: String?) -> Curve25519.KeyAgreement.PublicKey? {
        guard var digits = text?.utf8[...] else { return nil }
        if digits.count == 44, digits.last == UInt8(ascii: "=") { digits = digits.dropLast() }
        guard digits.count == 43, digits.allSatisfy(CloudflareAccessJWT.isBase64URL),
              let raw = Data(base64URL: String(decoding: digits, as: UTF8.self)) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    /// The session for `app` that `appToken` stands for. Its claims are read without checking the
    /// signature, as cloudflared does: the relay's encryption and the verified metadata vouch for
    /// where it came from, and Access and the Gateway check the token itself.
    static func validatedSession(appToken: String, for app: CloudflareAccessApplication, now: Date) throws -> CloudflareAccessSession {
        guard let claims = CloudflareAccessClaims(jwt: appToken), claims.kind == "app",
              claims.audiences.contains(app.audience), claims.issuer == "https://" + app.authDomain,
              claims.expiresAt > now, claims.notBefore.map({ $0 <= now.addingTimeInterval(60) }) ?? true,
              let origin = CloudflareAccessSession.origin(of: app.url),
              let session = CloudflareAccessSession(appToken: appToken, gatewayOrigin: origin, authDomain: app.authDomain,
                                                    audience: app.audience, subject: claims.subject) else { throw Failure.tokenInvalid.error }
        return session
    }

    // MARK: RS256

    /// An RSA public key from a JWK's unsigned big-endian modulus and exponent, imported through the
    /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    static func rsaPublicKey(n modulus: Data, e exponent: Data) -> SecKey? {
        let der = derElement(0x30, derElement(0x02, unsignedInteger(modulus)) + derElement(0x02, unsignedInteger(exponent)))
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        return SecKeyCreateWithData(Data(der) as CFData, attributes, nil)
    }

    /// RSASSA-PKCS1-v1_5 with SHA-256: the JWS algorithm `RS256`.
    static func verifiesRS256(_ signingInput: Data, signature: Data, key: SecKey) -> Bool {
        SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signature as CFData, nil)
    }

    fileprivate static func bitLength(_ magnitude: Data) -> Int {
        guard let first = magnitude.firstIndex(where: { $0 != 0 }) else { return 0 }
        return (magnitude.endIndex - first) * 8 - magnitude[first].leadingZeroBitCount
    }

    /// A DER element: the tag, the length in short or long form, then the contents.
    private static func derElement(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        var length: [UInt8] = []
        var count = contents.count
        if count < 0x80 { length = [UInt8(count)] } else {
            while count > 0 { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return [tag] + length + contents
    }

    /// INTEGER contents for an unsigned magnitude: no leading zeros, then one when the high bit is set.
    private static func unsignedInteger(_ magnitude: Data) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    /// Lowercases A–Z only, so that no other character can turn into an ASCII letter.
    fileprivate static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}

/// A `cf-access-metadata` JWS, parsed but not yet verified.
private struct SignedMetadata {
    let signingInput: Data
    let signature: Data
    let keyID: String
    let claims: JSONValue
    /// The canonical team domain the unverified claims name. Until the signature checks out, it only
    /// says where to fetch the keys, so it must be a Cloudflare Access team domain to be fetched from.
    let teamDomain: String

    /// Accepts only RS256, as go-jose's allow-list in cloudflared does, from a key named by `kid`.
    init(_ jws: String) throws {
        guard let segments = CloudflareAccessJWT.segments(jws),
              let header = CloudflareAccessJWT.object(segments[0]), header["alg"].stringValue == "RS256",
              let keyID = header["kid"].stringValue, !keyID.isEmpty,
              let claims = CloudflareAccessJWT.object(segments[1]),
              let teamDomain = claims["auth_domain"].stringValue.map(CloudflareAccessSignIn.asciiLowercased),
              CloudflareAccessSession.isTeamDomain(teamDomain),
              let signature = Data(base64URL: String(segments[2])) else { throw CloudflareAccessSignIn.Failure.metadataInvalid.error }
        signingInput = Data((segments[0] + "." + segments[1]).utf8)
        self.signature = signature; self.keyID = keyID; self.claims = claims; self.teamDomain = teamDomain
    }

    /// The application's audience, once the team's RSA key `keyID` of at least 2048 bits in `keys`
    /// verifies the signature and the claims describe the application at `host`, issued within the
    /// last 24 hours and at most 5 minutes ahead of `now` (cloudflared token/token.go).
    func verifiedAudience(keys: Data, host: String, now: Date) throws -> String {
        let jwk = (try? JSONDecoder().decode(JSONValue.self, from: keys))?["keys"].arrayValue?
            .first { $0["kty"].stringValue == "RSA" && $0["kid"].stringValue == keyID }
        let issuedAt = claims["iat"].numberValue ?? .nan
        guard let jwk, let modulus = jwk["n"].stringValue.flatMap(Data.init(base64URL:)),
              let exponent = jwk["e"].stringValue.flatMap(Data.init(base64URL:)),
              CloudflareAccessSignIn.bitLength(modulus) >= 2048,
              let key = CloudflareAccessSignIn.rsaPublicKey(n: modulus, e: exponent),
              CloudflareAccessSignIn.verifiesRS256(signingInput, signature: signature, key: key),
              claims["type"].stringValue == "match",
              let hostname = claims["hostname"].stringValue,
              CloudflareAccessSignIn.asciiLowercased(hostname) == CloudflareAccessSignIn.asciiLowercased(host),
              let audience = claims["aud"].stringValue, CloudflareAccessSession.isClaimValue(audience),
              issuedAt > 0, issuedAt >= now.timeIntervalSince1970 - 86_400, issuedAt <= now.timeIntervalSince1970 + 300
        else { throw CloudflareAccessSignIn.Failure.metadataInvalid.error }
        return audience
    }
}
