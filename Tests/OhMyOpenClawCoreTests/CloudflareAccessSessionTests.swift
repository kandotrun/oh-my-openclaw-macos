import Foundation
import Testing
@testable import OhMyOpenClawCore

/// Synthetic Access tokens and sessions. The signatures are placeholders: claims are read
/// without verification, and nothing here is a real credential.
enum AccessSessionFixture {
    static let audience = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    static let team = "team.cloudflareaccess.com"
    static let origin = "https://gateway.example.com"
    static let serviceToken = CloudflareAccessToken(clientID: "client.access", clientSecret: "client-secret")!
    static let rs256: JSONValue = .object(["alg": .string("RS256"), "kid": .string("fixture-key"), "typ": .string("JWT")])

    static var appClaims: [String: JSONValue] {
        [
            "type": .string("app"), "aud": .array([.string(audience)]), "iss": .string("https://" + team),
            "sub": .string("operator-subject"), "email": .string("operator@example.com"),
            "iat": .number(1_800_000_000), "nbf": .number(1_800_000_000), "exp": .number(1_800_086_400),
        ]
    }

    static func segment(_ value: JSONValue) -> String { try! JSONEncoder().encode(value).base64URL }
    static func jwt(header: JSONValue = rs256, claims: [String: JSONValue]) -> String {
        segment(header) + "." + segment(.object(claims)) + ".c2lnbmF0dXJl"
    }

    static let appToken = jwt(claims: appClaims)
    static let session = CloudflareAccessSession(appToken: appToken, gatewayOrigin: origin, authDomain: team, audience: audience, subject: "operator-subject")!

    static func session(appToken: String = appToken, gatewayOrigin: String = origin, authDomain: String = team,
                        audience: String = audience, subject: String = "operator-subject") -> CloudflareAccessSession? {
        CloudflareAccessSession(appToken: appToken, gatewayOrigin: gatewayOrigin, authDomain: authDomain, audience: audience, subject: subject)
    }
}

/// GatewayCredentials as builds without browser sign-in decode the same Keychain item.
private struct CredentialsWithoutSignIn: Codable, Equatable {
    var token: String?
    var password: String?
    var bootstrapToken: String?
    var deviceToken: String?
    var scopes: [String]?
    var access: CloudflareAccessToken?
}

@Suite("Cloudflare Access sessions")
struct CloudflareAccessSessionTests {
    private typealias Fixture = AccessSessionFixture

    @Test func sessionKeepsEveryVerifiedField() throws {
        let session = try #require(Fixture.session())
        #expect(session.appToken == Fixture.appToken)
        #expect(session.gatewayOrigin == "https://gateway.example.com")
        #expect(session.authDomain == "team.cloudflareaccess.com")
        #expect(session.audience == Fixture.audience)
        #expect(session.subject == "operator-subject")
    }

    @Test func appTokenMustBeACompactJWTOfAtMost16KiB() {
        #expect(Fixture.session(appToken: "aaaa.bbbb.cccc") != nil)
        #expect(Fixture.session(appToken: "a-_A.b9Z.c_-0") != nil)
        for token in ["", "aaaa.bbbb", "aaaa.bbbb.cccc.dddd", "aaaa..cccc", ".bbbb.cccc", "aaaa.bbbb.",
                      "aaaa.bb=b.cccc", "aaaa.bb+b.cccc", "aaaa.bb/b.cccc", " aaaa.bbbb.cccc", "aaaa.bbbb.cc cc",
                      "aaaa.bbbb.cccc\r\nX-Injected: 1", "aaaa.bbbb.cccc\n", "aaaa.bbbb.ccé", "aaaa.bbbb.cc\u{0}"] {
            #expect(Fixture.session(appToken: token) == nil, "\(token.debugDescription)")
        }
        let limit = "a.b." + String(repeating: "c", count: 16 * 1024 - 4)
        #expect(Fixture.session(appToken: limit) != nil)
        #expect(Fixture.session(appToken: limit + "c") == nil)
    }

    @Test func gatewayOriginMustBeCanonical() {
        for origin in ["https://gateway.example.com", "https://gateway.example.com:8443", "https://xn--bcher-kva.example",
                       "http://127.0.0.1:61234", "http://localhost:8080", "http://[::1]:8080", "http://127.0.0.1"] {
            #expect(Fixture.session(gatewayOrigin: origin) != nil, "\(origin)")
        }
        for origin in ["", "gateway.example.com", "https://", "https://gateway.example.com/", "https://gateway.example.com/openclaw",
                       "https://Gateway.example.com", "HTTPS://gateway.example.com", "https://gateway.example.com:443",
                       "https://gateway.example.com:", "https://gateway.example.com:0", "https://gateway.example.com:99999",
                       "http://gateway.example.com", "http://127.0.0.1:80", "wss://gateway.example.com", "ws://127.0.0.1:61234",
                       "https://user@gateway.example.com", "https://gateway.example.com?x=1", "https://gateway.example.com#x",
                       "ftp://gateway.example.com", "https://gateway.example.com\r\n"] {
            #expect(Fixture.session(gatewayOrigin: origin) == nil, "\(origin.debugDescription)")
        }
    }

    @Test func authDomainMustBeABareCloudflareAccessTeamDomain() {
        for domain in ["team.cloudflareaccess.com", "team.fed.cloudflareaccess.com", "my-team1.cloudflareaccess.com",
                       String(repeating: "a", count: 63) + ".cloudflareaccess.com"] {
            #expect(Fixture.session(authDomain: domain) != nil, "\(domain)")
        }
        for domain in ["", "evil.example.com", "team.cloudflareaccess.com.evil.com", "team.cloudflareaccess.com:443",
                       "cloudflareaccess.com", ".cloudflareaccess.com", "team..cloudflareaccess.com", "Team.cloudflareaccess.com",
                       "https://team.cloudflareaccess.com", "team.cloudflareaccess.com/", "team.cloudflareaccess.com.",
                       "-team.cloudflareaccess.com", "team-.cloudflareaccess.com", "tëam.cloudflareaccess.com",
                       "team_1.cloudflareaccess.com", "user@team.cloudflareaccess.com", "team.cloudflareaccess.org",
                       String(repeating: "a", count: 64) + ".cloudflareaccess.com"] {
            #expect(Fixture.session(authDomain: domain) == nil, "\(domain.debugDescription)")
        }
    }

    @Test func audienceAndSubjectAreBoundedSingleLineValues() {
        let longest = String(repeating: "s", count: 512)
        #expect(Fixture.session(audience: longest, subject: longest) != nil)
        #expect(Fixture.session(subject: String(repeating: "é", count: 256)) != nil)
        for value in ["", longest + "s", String(repeating: "é", count: 257), "line\nbreak", "carriage\rreturn", "nul\u{0}byte", "tab\tvalue"] {
            #expect(Fixture.session(audience: value) == nil, "\(value.debugDescription)")
            #expect(Fixture.session(subject: value) == nil, "\(value.debugDescription)")
        }
    }

    @Test func sessionSendsOnlyCfAccessTokenAndOnlyToItsGatewayOrigin() throws {
        let session = Fixture.session
        for url in ["https://gateway.example.com/", "https://gateway.example.com/api/artifacts/download/1?x=1",
                    "wss://gateway.example.com/openclaw", "https://GATEWAY.example.com:443/path", "wss://gateway.example.com:443"] {
            var request = URLRequest(url: try #require(URL(string: url)))
            session.apply(to: &request)
            #expect(request.allHTTPHeaderFields == ["Cf-Access-Token": Fixture.appToken], "\(url)")
        }
        for url in ["https://gateway.example.com:8443/", "http://gateway.example.com/", "ws://gateway.example.com/",
                    "https://other.example.com/", "https://gateway.example.com.evil.com/", "https://evil.com/gateway.example.com",
                    "https://team.cloudflareaccess.com/cdn-cgi/access/login", "https://user@gateway.example.com/"] {
            var request = URLRequest(url: try #require(URL(string: url)))
            session.apply(to: &request)
            #expect((request.allHTTPHeaderFields ?? [:]).isEmpty, "\(url)")
        }
        var detached = URLRequest(url: try #require(URL(string: "https://gateway.example.com/")))
        detached.url = nil
        session.apply(to: &detached)
        #expect((detached.allHTTPHeaderFields ?? [:]).isEmpty)
    }

    @Test func loopbackSessionReachesOnlyItsOwnPort() throws {
        let session = try #require(Fixture.session(gatewayOrigin: "http://127.0.0.1:61234"))
        var upgrade = URLRequest(url: try #require(URL(string: "ws://127.0.0.1:61234/")))
        session.apply(to: &upgrade)
        #expect(upgrade.value(forHTTPHeaderField: "Cf-Access-Token") == Fixture.appToken)
        var otherPort = URLRequest(url: try #require(URL(string: "ws://127.0.0.1:61235/")))
        session.apply(to: &otherPort)
        #expect(otherPort.value(forHTTPHeaderField: "Cf-Access-Token") == nil)
    }

    @Test func requestsCarryTheSessionWhenOneIsSavedAndTheServiceTokenOtherwise() {
        #expect(GatewayCredentials(token: "gateway-token").accessCredential == nil)
        #expect(GatewayCredentials(access: Fixture.serviceToken).accessCredential as? CloudflareAccessToken == Fixture.serviceToken)
        #expect(GatewayCredentials(accessSession: Fixture.session).accessCredential as? CloudflareAccessSession == Fixture.session)
        // Only hand-edited data holds both; the session wins and the service token stays unsent.
        let both = GatewayCredentials(access: Fixture.serviceToken, accessSession: Fixture.session)
        #expect(both.accessCredential as? CloudflareAccessSession == Fixture.session)
    }

    @Test func oneAccessCredentialPerGateway() throws {
        let endpoint = try #require(URL(string: "wss://gateway.example.com/openclaw"))
        let otherToken = try #require(CloudflareAccessToken(clientID: "other.access", clientSecret: "other-secret"))
        let entered = GatewayCredentials(token: "gateway-token", bootstrapToken: "bootstrap", deviceToken: "device", scopes: ["operator.read"])
        let storedCases: [GatewayCredentials?] = [
            nil,
            GatewayCredentials(deviceToken: "stored-device", scopes: ["operator.write"], access: Fixture.serviceToken),
            GatewayCredentials(token: "stored-token", accessSession: Fixture.session),
        ]
        for stored in storedCases {
            let kept = entered.applying(.keep, savedWith: stored, for: endpoint)
            #expect(kept.access == stored?.access)
            #expect(kept.accessSession == stored?.accessSession)

            let serviceToken = entered.applying(.serviceToken(otherToken), savedWith: stored, for: endpoint)
            #expect(serviceToken.access == otherToken)
            #expect(serviceToken.accessSession == nil)

            let signedIn = entered.applying(.session(Fixture.session), savedWith: stored, for: endpoint)
            #expect(signedIn.accessSession == Fixture.session)
            #expect(signedIn.access == nil)
            // A device token paired before the sign-in would connect without the person.
            #expect(signedIn.deviceToken == nil)
            #expect(signedIn.scopes == nil)

            for (result, keepsDeviceToken) in [(kept, true), (serviceToken, true), (signedIn, false)] {
                #expect(result.access == nil || result.accessSession == nil)
                // Everything else is what the caller entered.
                #expect(result.token == "gateway-token")
                #expect(result.bootstrapToken == "bootstrap")
                #expect(result.password == nil)
                #expect(result.deviceToken == (keepsDeviceToken ? "device" : nil))
                #expect(result.scopes == (keepsDeviceToken ? ["operator.read"] : nil))
            }
        }
    }

    @Test func aSessionForAnotherOriginLeavesTheSavedCredentialsUnchanged() throws {
        let stored = GatewayCredentials(deviceToken: "stored-device", scopes: ["operator.read"], access: Fixture.serviceToken)
        let entered = GatewayCredentials(bootstrapToken: "bootstrap")
        for text in ["wss://other.example.com/", "wss://gateway.example.com:8443/", "ws://gateway.example.com/", "ws://127.0.0.1:61234/"] {
            let endpoint = try #require(URL(string: text))
            #expect(entered.applying(.session(Fixture.session), savedWith: stored, for: endpoint) == stored, "\(text)")
            #expect(entered.applying(.session(Fixture.session), savedWith: nil, for: endpoint) == GatewayCredentials(), "\(text)")
        }
        let loopback = try #require(Fixture.session(gatewayOrigin: "http://127.0.0.1:61234"))
        let signedIn = entered.applying(.session(loopback), savedWith: stored, for: try #require(URL(string: "ws://127.0.0.1:61234/")))
        #expect(signedIn.accessSession == loopback)
        #expect(signedIn.access == nil)
    }

    @Test func sessionRoundTripsAndDecodingRevalidatesEveryField() throws {
        let data = try JSONEncoder().encode(Fixture.session)
        #expect(try JSONDecoder().decode(CloudflareAccessSession.self, from: data) == Fixture.session)
        let saved = try JSONDecoder().decode([String: String].self, from: data)
        #expect(Set(saved.keys) == ["appToken", "gatewayOrigin", "authDomain", "audience", "subject"])
        for (key, value) in [("appToken", "aaaa.bbbb.cccc\r\nX-Injected: 1"), ("gatewayOrigin", "https://gateway.example.com/"),
                             ("authDomain", "team.example.com"), ("audience", ""), ("subject", "")] {
            var edited = saved
            edited[key] = value
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(CloudflareAccessSession.self, from: JSONEncoder().encode(edited)) }
        }
        var missing = saved
        missing["subject"] = nil
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CloudflareAccessSession.self, from: JSONEncoder().encode(missing)) }
    }

    @Test func aSavedSessionThatFailsValidationIsDroppedAndTheRestStaysReadable() throws {
        let session = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(Fixture.session))
        var badToken = session
        badToken["appToken"] = "aaaa.bbbb.cccc\r\nX-Injected: 1"
        var badDomain = session
        badDomain["authDomain"] = "team.example.com"
        let rest: [String: JSONValue] = [
            "deviceToken": .string("device"), "scopes": .array([.string("operator.read")]),
            "access": .object(["clientID": .string("client.access"), "clientSecret": .string("client-secret")]),
        ]
        for bad in [JSONValue.object(badToken.mapValues(JSONValue.string)), .object(badDomain.mapValues(JSONValue.string)), .string("not a session"), .array([])] {
            var saved = rest
            saved["accessSession"] = bad
            let credentials = try JSONDecoder().decode(GatewayCredentials.self, from: JSONEncoder().encode(JSONValue.object(saved)))
            #expect(credentials.accessSession == nil)
            #expect(credentials == GatewayCredentials(deviceToken: "device", scopes: ["operator.read"], access: Fixture.serviceToken))
        }
        // Only the session is lenient: other malformed fields still fail as before.
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GatewayCredentials.self, from: Data(#"{"deviceToken":5}"#.utf8)) }
    }

    @Test func credentialsSavedBeforeSignInSupportStillLoadAndSessionsRoundTrip() throws {
        let saved = #"{"deviceToken":"device","scopes":["operator.read"],"access":{"clientID":"client.access","clientSecret":"client-secret"}}"#
        let credentials = try JSONDecoder().decode(GatewayCredentials.self, from: Data(saved.utf8))
        #expect(credentials == GatewayCredentials(deviceToken: "device", scopes: ["operator.read"], access: Fixture.serviceToken))
        #expect(credentials.accessSession == nil)
        let signedIn = GatewayCredentials(token: "gateway-token", accessSession: Fixture.session)
        #expect(try JSONDecoder().decode(GatewayCredentials.self, from: JSONEncoder().encode(signedIn)) == signedIn)
        // A session absent from the struct adds no key, as before.
        let plain = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(GatewayCredentials(token: "gateway-token")))
        #expect(Set(plain.keys) == ["token"])
    }

    @Test func credentialsWithASessionStillLoadInBuildsWithoutSignIn() throws {
        let current = GatewayCredentials(token: "t", password: "p", bootstrapToken: "b", deviceToken: "d", scopes: ["operator.read"],
                                         access: Fixture.serviceToken, accessSession: Fixture.session)
        let older = try JSONDecoder().decode(CredentialsWithoutSignIn.self, from: JSONEncoder().encode(current))
        #expect(older == CredentialsWithoutSignIn(token: "t", password: "p", bootstrapToken: "b", deviceToken: "d",
                                                 scopes: ["operator.read"], access: Fixture.serviceToken))
    }
}

@Suite("Cloudflare Access token claims")
struct CloudflareAccessClaimsTests {
    private typealias Fixture = AccessSessionFixture

    @Test func appTokenClaimsDecodeWithoutCheckingTheSignature() throws {
        let claims = try #require(CloudflareAccessClaims(jwt: Fixture.appToken))
        #expect(claims.kind == "app")
        #expect(claims.audiences == [Fixture.audience])
        #expect(claims.issuer == "https://team.cloudflareaccess.com")
        #expect(claims.subject == "operator-subject")
        #expect(claims.email == "operator@example.com")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 1_800_086_400))
        #expect(claims.notBefore == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(CloudflareAccessClaims(jwt: Fixture.appToken) == claims)
    }

    @Test func audienceIsAStringOrAnArrayOfStrings() throws {
        var single = Fixture.appClaims
        single["aud"] = .string(Fixture.audience)
        #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: single))?.audiences == [Fixture.audience])
        var several = Fixture.appClaims
        several["aud"] = .array([.string("first"), .string(Fixture.audience)])
        #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: several))?.audiences == ["first", Fixture.audience])
        for aud: JSONValue? in [nil, .null, .number(1), .object([:]), .array([.string(Fixture.audience), .number(1)])] {
            var claims = Fixture.appClaims
            claims["aud"] = aud
            #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: claims)) == nil, "\(String(describing: aud))")
        }
    }

    @Test func emailAndNotBeforeAreOptional() throws {
        var claims = Fixture.appClaims
        claims["email"] = nil
        claims["nbf"] = nil
        var org = claims
        org["type"] = .string("org")
        org["exp"] = .number(1_800_000_000.5)
        let decoded = try #require(CloudflareAccessClaims(jwt: Fixture.jwt(claims: org)))
        #expect(decoded.kind == "org")
        #expect(decoded.email == nil)
        #expect(decoded.notBefore == nil)
        #expect(decoded.expiresAt == Date(timeIntervalSince1970: 1_800_000_000.5))
        claims["email"] = .null
        claims["nbf"] = .null
        #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: claims))?.email == nil)
    }

    @Test func everyClaimMustHaveItsType() {
        let required = ["type", "aud", "iss", "sub", "exp"]
        for name in required {
            var missing = Fixture.appClaims
            missing[name] = nil
            #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: missing)) == nil, "missing \(name)")
        }
        for (name, value): (String, JSONValue) in [("type", .number(1)), ("iss", .bool(true)), ("sub", .array([])), ("exp", .string("1800086400")),
                                                   ("email", .number(1)), ("nbf", .string("1800000000"))] {
            var wrong = Fixture.appClaims
            wrong[name] = value
            #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: wrong)) == nil, "wrong \(name)")
        }
    }

    @Test func onlyRS256CompactTokensOfAtMost16KiBDecode() {
        for header: JSONValue in [.object(["alg": .string("none")]), .object(["alg": .string("HS256")]), .object(["alg": .string("rs256")]),
                                  .object(["kid": .string("fixture-key")]), .array([.string("RS256")])] {
            #expect(CloudflareAccessClaims(jwt: Fixture.jwt(header: header, claims: Fixture.appClaims)) == nil, "\(header)")
        }
        let header = Fixture.segment(Fixture.rs256)
        let payload = Fixture.segment(.object(Fixture.appClaims))
        for token in [header + "." + payload, header + "." + payload + ".", header + "." + payload + ".sig.extra",
                      header + "." + payload + ".sig=", header + ".!!!!." + "sig", header + "." + Fixture.segment(.array([])) + ".sig",
                      header + "." + Data("{not json".utf8).base64URL + ".sig", header + "." + payload + ".sig\n"] {
            #expect(CloudflareAccessClaims(jwt: token) == nil, "\(token.debugDescription)")
        }
        var padded = Fixture.appClaims
        padded["padding"] = .string(String(repeating: "x", count: 16 * 1024))
        #expect(CloudflareAccessClaims(jwt: Fixture.jwt(claims: padded)) == nil)
    }
}
