import CryptoKit
import Foundation
import Security
import Testing
@testable import OhMyOpenClawCore

/// The RSA key and RS256 example of RFC 7515 Appendix A.2, published for testing. Tests sign
/// metadata with it through Security, which reproduces the RFC signature byte for byte.
enum RFC7515 {
    static let keyID = "fixture-rfc7515"
    static let n = "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ"
    static let e = "AQAB"
    static let d = "Eq5xpGnNCivDflJsRQBXHx1hdR1k6Ulwe2JZD50LpXyWPEAeP88vLNO97IjlA7_GQ5sLKMgvfTeXZx9SE-7YwVol2NXOoAJe46sui395IW_GO-pWJ1O0BkTGoVEn2bKVRUCgu-GjBVaYLU6f3l9kJfFNS3E0QbVdxzubSu3Mkqzjkn439X0M_V51gfpRLI9JYanrC4D4qAdGcopV_0ZHHzQlBjudU2QvXt4ehNYTCBr6XCLQUShb1juUO1ZdiYoFaFQT5Tw8bGUl_x_jTj3ccPDVZFD9pIuhLhBOneufuBiB4cS98l2SR_RQyGWSeWjnczT0QU91p1DhOVRuOopznQ"
    static let p = "4BzEEOtIpmVdVEZNCqS7baC4crd0pqnRH_5IB3jw3bcxGn6QLvnEtfdUdiYrqBdss1l58BQ3KhooKeQTa9AB0Hw_Py5PJdTJNPY8cQn7ouZ2KKDcmnPGBY5t7yLc1QlQ5xHdwW1VhvKn-nXqhJTBgIPgtldC-KDV5z-y2XDwGUc"
    static let q = "uQPEfgmVtjL0Uyyx88GZFF1fOunH3-7cepKmtH4pxhtCoHqpWmT8YAmZxaewHgHAjLYsp1ZSe7zFYHj7C6ul7TjeLQeZD_YwD66t62wDmpe_HlB-TnBA-njbglfIsRLtXlnDzQkv5dTltRJ11BKBBypeeF6689rjcJIDEz9RWdc"
    static let dp = "BwKfV3Akq5_MFZDFZCnW-wzl-CCo83WoZvnLQwCTeDv8uzluRSnm71I3QCLdhrqE2e9YkxvuxdBfpT_PI7Yz-FOKnu1R6HsJeDCjn12Sk3vmAktV2zb34MCdy7cpdTh_YVr7tss2u6vneTwrA86rZtu5Mbr1C1XsmvkxHQAdYo0"
    static let dq = "h_96-mK1R_7glhsum81dZxjTnYynPbZpHziZjeeHcXYsXaaMwkOlODsWa7I9xXDoRwbKgB719rrmI2oKr6N3Do9U0ajaHF-NKJnwgjMd2w9cjz3_-kyNlxAr2v4IKhGNpmM5iIgOS1VZnOZ68m6_pbLBSp3nssTdlqvd0tIiTHU"
    static let qi = "IYd7DHOhrWvxkwPQsRM2tOgrjbcrfvtQJipd-DlcxyVuuM9sQLdgjVk2oy26F0EmpScGLq2MowX7fhd_QJQ3ydy5cY7YIBi87w93IKLEdfnbJtoOPLUW0ITrJReOgo1cq9SbsxYawBgfp_gh6A5603k2-ZQwVK0JKSHuLFkuQ3U"
    static let signingInput = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ"
    static let signature = "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw"

    /// The public half as a team's `/cdn-cgi/access/certs` lists it.
    static let jwk: JSONValue = .object(["kty": .string("RSA"), "kid": .string(keyID), "alg": .string("RS256"), "use": .string("sig"),
                                          "n": .string(n), "e": .string(e)])

    /// The key from its PKCS#1 RSAPrivateKey DER.
    static func privateKey() throws -> SecKey {
        let integers = [Data([0])] + [n, e, d, p, q, dp, dq, qi].map { Data(base64URL: $0)! }
        return try TestRSA.key(TestDER.sequence(integers.map(TestDER.integer)), class: kSecAttrKeyClassPrivate)
    }

    static func sign(_ input: String) throws -> String { try TestRSA.sign(input, with: privateKey()) }
}

/// RSA keys through Security, for tests.
enum TestRSA {
    static func key(_ der: Data, class keyClass: CFString) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: keyClass] as CFDictionary
        guard let key = SecKeyCreateWithData(der as CFData, attributes, &error) else { throw error!.takeRetainedValue() }
        return key
    }

    static func sign(_ input: String, with key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) else {
            throw error!.takeRetainedValue()
        }
        return (signature as Data).base64URL
    }

    /// A fresh key pair of `bits` bits, and its public half as a JWK with `kid`.
    static func generate(bits: Int, kid: String) throws -> (privateKey: SecKey, jwk: JSONValue) {
        var error: Unmanaged<CFError>?
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits] as CFDictionary
        guard let key = SecKeyCreateRandomKey(attributes, &error) else { throw error!.takeRetainedValue() }
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
        let (modulus, exponent) = try #require(TestDER.rsaPublicKey(der))
        return (key, .object(["kty": .string("RSA"), "kid": .string(kid), "n": .string(modulus.base64URL), "e": .string(exponent.base64URL)]))
    }
}

/// Just enough DER to build and read RSA keys in tests.
enum TestDER {
    static func length(_ count: Int) -> [UInt8] {
        guard count >= 0x80 else { return [UInt8(count)] }
        var bytes: [UInt8] = []; var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func integer(_ magnitude: Data) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return [0x02] + length(bytes.count) + bytes
    }

    static func sequence(_ elements: [[UInt8]]) -> Data {
        let body = elements.flatMap { $0 }
        return Data([0x30] + length(body.count) + body)
    }

    /// The unsigned modulus and exponent of a PKCS#1 RSAPublicKey.
    static func rsaPublicKey(_ der: Data) -> (Data, Data)? {
        var bytes = [UInt8](der)[...]
        func element(_ tag: UInt8) -> ArraySlice<UInt8>? {
            guard bytes.popFirst() == tag, var count = bytes.popFirst().map(Int.init) else { return nil }
            if count & 0x80 != 0 {
                let lengthBytes = count & 0x7f
                count = 0
                for _ in 0..<lengthBytes { guard let byte = bytes.popFirst() else { return nil }; count = count << 8 | Int(byte) }
            }
            guard bytes.count >= count else { return nil }
            defer { bytes = bytes.dropFirst(count) }
            return bytes.prefix(count)
        }
        guard let sequence = element(0x30) else { return nil }
        bytes = sequence
        guard let modulus = element(0x02), let exponent = element(0x02) else { return nil }
        return (Data(modulus.drop { $0 == 0 }), Data(exponent.drop { $0 == 0 }))
    }
}

/// A signed `cf-access-metadata` answer for wss://gateway.example.com/openclaw, as the Access edge
/// sends it at `now`, and the team's key set.
enum DiscoveryFixture {
    static let now = AccessSignInFixture.now
    static let endpoint = URL(string: "wss://gateway.example.com/openclaw")!
    static let header: JSONValue = .object(["alg": .string("RS256"), "kid": .string(RFC7515.keyID), "typ": .string("JWT")])
    static var claims: [String: JSONValue] {
        ["type": .string("match"), "hostname": .string("gateway.example.com"), "auth_domain": .string("team.cloudflareaccess.com"),
         "aud": .string(AccessSignInFixture.audience), "app_hostname": .string("gateway.example.com"), "iat": .number(now.timeIntervalSince1970)]
    }

    /// Another key the team publishes; it did not sign anything here.
    static var decoy: JSONValue {
        var modulus = Data(base64URL: RFC7515.n)!
        modulus[modulus.count - 1] ^= 0x02
        return .object(["kty": .string("RSA"), "kid": .string("decoy"), "n": .string(modulus.base64URL), "e": .string(RFC7515.e)])
    }

    static func metadata(header: JSONValue = header, claims: [String: JSONValue] = claims, sign: ((String) throws -> String)? = nil) throws -> String {
        let input = AccessSessionFixture.segment(header) + "." + AccessSessionFixture.segment(.object(claims))
        return try input + "." + (sign ?? RFC7515.sign)(input)
    }

    static func keys(_ keys: [JSONValue] = [decoy, RFC7515.jwk]) -> Data {
        try! JSONEncoder().encode(JSONValue.object(["keys": .array(keys)]))
    }

    /// The edge's metadata answer, then the team domain's key set.
    static func edge(metadata: String, keys: ScriptedFetch.Answer = .status(200, headers: ["Content-Type": "application/json"], body: keys())) -> ScriptedFetch {
        ScriptedFetch([.status(200, headers: ["cf-access-metadata": metadata]), keys])
    }
}

private func lowercasedHeaders(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
}

@Suite("Cloudflare Access application discovery")
struct CloudflareAccessDiscoveryTests {
    private typealias Fixture = DiscoveryFixture

    private func discover(_ edge: ScriptedFetch, endpoint: URL = Fixture.endpoint,
                          endpoints: CloudflareAccessEndpoints = .cloudflare) async throws -> CloudflareAccessApplication {
        try await CloudflareAccessSignIn.discover(endpoint, endpoints: endpoints, now: Fixture.now) { try await edge.fetch($0, $1) }
    }

    private func claims(_ edit: (inout [String: JSONValue]) -> Void) -> [String: JSONValue] {
        var claims = Fixture.claims
        edit(&claims)
        return claims
    }

    // MARK: RS256

    @Test func rs256VerifiesTheRFC7515Example() throws {
        let modulus = try #require(Data(base64URL: RFC7515.n)), exponent = try #require(Data(base64URL: RFC7515.e))
        let key = try #require(CloudflareAccessSignIn.rsaPublicKey(n: modulus, e: exponent))
        let input = Data(RFC7515.signingInput.utf8)
        let signature = try #require(Data(base64URL: RFC7515.signature))
        #expect(CloudflareAccessSignIn.verifiesRS256(input, signature: signature, key: key))
        var tampered = signature
        tampered[0] ^= 1
        #expect(!CloudflareAccessSignIn.verifiesRS256(input, signature: tampered, key: key))
        #expect(!CloudflareAccessSignIn.verifiesRS256(Data((RFC7515.signingInput + "x").utf8), signature: signature, key: key))
        #expect(!CloudflareAccessSignIn.verifiesRS256(input, signature: signature.dropLast(), key: key))
        // A leading zero byte in the published modulus changes nothing.
        let padded = try #require(CloudflareAccessSignIn.rsaPublicKey(n: Data([0]) + modulus, e: exponent))
        #expect(CloudflareAccessSignIn.verifiesRS256(input, signature: signature, key: padded))
    }

    @Test func theTestSignerReproducesTheRFC7515Signature() throws {
        #expect(try RFC7515.sign(RFC7515.signingInput) == RFC7515.signature)
    }

    // MARK: Discovery

    @Test func discoverTrustsTheApplicationOnlyAfterVerifyingItsSignedMetadata() async throws {
        let edge = Fixture.edge(metadata: try Fixture.metadata())
        let app = try await discover(edge)
        #expect(app == CloudflareAccessApplication(url: try #require(URL(string: "https://gateway.example.com/openclaw")),
                                                   authDomain: "team.cloudflareaccess.com", audience: AccessSignInFixture.audience))
        let requests = await edge.requests
        try #require(requests.count == 2)
        let probe = requests[0], keys = requests[1]
        #expect(probe.httpMethod == "HEAD")
        #expect(probe.url?.absoluteString == "https://gateway.example.com/openclaw")
        // Nothing else: no Cookie, Authorization, Cf-Access-Token or service token.
        #expect(lowercasedHeaders(probe) == ["cf-access-metadata-request": "true"])
        #expect(probe.httpBody == nil)
        #expect(probe.timeoutInterval == 7)
        #expect(keys.httpMethod == "GET")
        #expect(keys.url?.absoluteString == "https://team.cloudflareaccess.com/cdn-cgi/access/certs")
        #expect(lowercasedHeaders(keys).isEmpty)
        #expect(keys.timeoutInterval == 10)
        #expect(await edge.limits == [0, 1_048_576])
    }

    @Test func theStatusOfTheMetadataAnswerDoesNotMatter() async throws {
        // A plain request is redirected to the login page; the signed header is what counts.
        let edge = ScriptedFetch([
            .status(302, headers: ["cf-access-metadata": try Fixture.metadata(), "Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/gateway.example.com"]),
            .status(200, body: Fixture.keys()),
        ])
        #expect(try await discover(edge).audience == AccessSignInFixture.audience)
    }

    @Test func noMetadataHeaderMeansNoAccessApplication() async {
        for headers in [[:], ["cf-access-metadata": ""]] {
            let edge = ScriptedFetch([.status(200, headers: headers)])
            #expect(await failureCode { try await discover(edge) } == "ACCESS_NOT_PROTECTED", "\(headers)")
            #expect(await edge.requests.count == 1)
        }
    }

    @Test func networkFailuresMeanAccessIsUnreachable() async throws {
        let probeFails = ScriptedFetch([.failure(.notConnectedToInternet)])
        #expect(await failureCode { try await discover(probeFails) } == "ACCESS_UNREACHABLE")
        let keysFail = Fixture.edge(metadata: try Fixture.metadata(), keys: .failure(.timedOut))
        #expect(await failureCode { try await discover(keysFail) } == "ACCESS_UNREACHABLE")
        #expect(await keysFail.requests.count == 2)
    }

    @Test func theKeySetMustBeAPlainSmallJSONAnswer() async throws {
        let metadata = try Fixture.metadata()
        let keys = Fixture.keys()
        let cases: [(String, ScriptedFetch.Answer)] = [
            ("404", .status(404, body: keys)), ("500", .status(500, body: keys)),
            ("redirect", .status(302, headers: ["Location": "https://evil.example.com/certs"], body: keys)),
            // Trailing spaces keep it valid JSON, so only the 1 MiB cap can refuse it.
            ("over 1 MiB", .status(200, body: keys + Data(repeating: 0x20, count: 1_048_576))),
            ("not JSON", .status(200, body: Data("not json".utf8))), ("no keys", .status(200, body: Data("{}".utf8))),
            ("keys not an array", .status(200, body: Data(#"{"keys":{}}"#.utf8))),
        ]
        for (name, answer) in cases {
            let edge = Fixture.edge(metadata: metadata, keys: answer)
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(name)")
        }
        let exactlyAtTheCap = keys + Data(repeating: 0x20, count: 1_048_576 - keys.count)
        #expect(try await discover(Fixture.edge(metadata: metadata, keys: .status(200, body: exactlyAtTheCap))).authDomain == "team.cloudflareaccess.com")
    }

    @Test func theMetadataMustBeSignedWithRS256ByTheNamedTeamKey() async throws {
        let signed = try Fixture.metadata()
        let parts = signed.split(separator: ".").map(String.init)
        var tampered = try #require(Data(base64URL: parts[2]))
        tampered[10] ^= 1
        let hmacKey = SymmetricKey(data: try #require(Data(base64URL: RFC7515.n)))
        func header(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
        let cases: [(String, String)] = [
            ("tampered signature", parts[0] + "." + parts[1] + "." + tampered.base64URL),
            ("claims swapped after signing", parts[0] + "." + AccessSessionFixture.segment(.object(claims { $0["aud"] = .string("other-aud") })) + "." + parts[2]),
            ("alg none, unsigned", try Fixture.metadata(header: header(["alg": .string("none"), "kid": .string(RFC7515.keyID)]), sign: { _ in "" })),
            ("alg none, signed", try Fixture.metadata(header: header(["alg": .string("none"), "kid": .string(RFC7515.keyID)]))),
            ("HS256 keyed with the public modulus", try Fixture.metadata(header: header(["alg": .string("HS256"), "kid": .string(RFC7515.keyID)]),
                                                                          sign: { Data(HMAC<SHA256>.authenticationCode(for: Data($0.utf8), using: hmacKey)).base64URL })),
            ("alg in another case", try Fixture.metadata(header: header(["alg": .string("rs256"), "kid": .string(RFC7515.keyID)]))),
            ("no kid", try Fixture.metadata(header: header(["alg": .string("RS256")]))),
            ("empty kid", try Fixture.metadata(header: header(["alg": .string("RS256"), "kid": .string("")]))),
            ("unknown kid", try Fixture.metadata(header: header(["alg": .string("RS256"), "kid": .string("rotated-away")]))),
            ("the kid of another key", try Fixture.metadata(header: header(["alg": .string("RS256"), "kid": .string("decoy")]))),
        ]
        for (name, metadata) in cases {
            let edge = Fixture.edge(metadata: metadata)
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(name)")
        }
    }

    @Test func onlyAnRSAKeyOfAtLeast2048BitsCanVouchForTheApplication() async throws {
        let metadata = try Fixture.metadata()
        for (name, keys) in [("EC key with the kid", [JSONValue.object(["kty": .string("EC"), "kid": .string(RFC7515.keyID), "crv": .string("P-256")])]),
                             ("RSA key without n", [.object(["kty": .string("RSA"), "kid": .string(RFC7515.keyID), "e": .string(RFC7515.e)])])] {
            let edge = Fixture.edge(metadata: metadata, keys: .status(200, body: Fixture.keys(keys)))
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(name)")
        }
        for (bits, accepted) in [(1024, false), (2048, true)] {
            let generated = try TestRSA.generate(bits: bits, kid: "generated")
            let signed = try Fixture.metadata(header: .object(["alg": .string("RS256"), "kid": .string("generated")])) { try TestRSA.sign($0, with: generated.privateKey) }
            let edge = Fixture.edge(metadata: signed, keys: .status(200, body: Fixture.keys([generated.jwk])))
            #expect(await failureCode { try await discover(edge) } == (accepted ? nil : "ACCESS_METADATA_INVALID"), "\(bits) bits")
        }
    }

    @Test func aKeyOfAnotherTypeWithTheSameKidDoesNotHideTheRSAKey() async throws {
        // Listed first, the EC key would be the one found if keys were matched by kid alone.
        let ec = JSONValue.object(["kty": .string("EC"), "kid": .string(RFC7515.keyID), "crv": .string("P-256")])
        let edge = Fixture.edge(metadata: try Fixture.metadata(), keys: .status(200, body: Fixture.keys([ec, RFC7515.jwk])))
        #expect(try await discover(edge).audience == AccessSignInFixture.audience)
    }

    @Test func malformedMetadataIsRejectedBeforeAnyKeyFetch() async throws {
        let signed = try Fixture.metadata()
        let parts = signed.split(separator: ".").map(String.init)
        let oversized = try Fixture.metadata(claims: claims { $0["padding"] = .string(String(repeating: "x", count: 16 * 1024)) })
        for (name, metadata) in [("two segments", parts[0] + "." + parts[1]), ("four segments", signed + ".extra"),
                                 ("spaces", signed.replacingOccurrences(of: ".", with: ". ")), ("not a JWS", "not a jws"),
                                 ("header not JSON", Data("nope".utf8).base64URL + "." + parts[1] + "." + parts[2]),
                                 ("header an array", AccessSessionFixture.segment(.array([.string("RS256")])) + "." + parts[1] + "." + parts[2]),
                                 ("claims not an object", parts[0] + "." + AccessSessionFixture.segment(.string("match")) + "." + parts[2]),
                                 ("over 16 KiB", oversized)] {
            let edge = Fixture.edge(metadata: metadata)
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(name)")
            #expect(await edge.requests.count == 1, "\(name)")
        }
    }

    @Test func theAuthDomainMustBeACloudflareAccessTeamDomain() async throws {
        for domain in ["evil.example.com", "team.cloudflareaccess.com.evil.com", "team.cloudflareaccess.com:443", "cloudflareaccess.com",
                       "https://team.cloudflareaccess.com", "team.cloudflareaccess.com/", "user@team.cloudflareaccess.com",
                       "team.cloudflareaccess.com.", "team\u{212A}.cloudflareaccess.com", "team.cloudflareaccess.org", ""] {
            let edge = Fixture.edge(metadata: try Fixture.metadata(claims: claims { $0["auth_domain"] = .string(domain) }))
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(domain.debugDescription)")
            // Keys are never fetched from a host that is not a team domain.
            #expect(await edge.requests.count == 1, "\(domain.debugDescription)")
        }
        for value: JSONValue? in [nil, .number(1), .array([.string("team.cloudflareaccess.com")])] {
            let edge = Fixture.edge(metadata: try Fixture.metadata(claims: claims { $0["auth_domain"] = value }))
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(String(describing: value))")
            #expect(await edge.requests.count == 1)
        }
    }

    @Test func theAuthDomainIsLowercasedBeforeUse() async throws {
        let edge = Fixture.edge(metadata: try Fixture.metadata(claims: claims { $0["auth_domain"] = .string("TEAM.CloudflareAccess.COM") }))
        #expect(try await discover(edge).authDomain == "team.cloudflareaccess.com")
        #expect(await edge.requests.last?.url?.absoluteString == "https://team.cloudflareaccess.com/cdn-cgi/access/certs")
    }

    @Test func theSignedClaimsMustDescribeThisGatewayNow() async throws {
        let now = Fixture.now.timeIntervalSince1970
        let accepted: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("hostname in another case", { $0["hostname"] = .string("GATEWAY.example.com") }),
            ("issued 24 h ago", { $0["iat"] = .number(now - 86_400) }),
            ("issued 5 min ahead", { $0["iat"] = .number(now + 300) }),
            ("512-byte aud", { $0["aud"] = .string(String(repeating: "a", count: 512)) }),
            ("no app_hostname", { $0["app_hostname"] = nil }),
        ]
        for (name, edit) in accepted {
            let edge = Fixture.edge(metadata: try Fixture.metadata(claims: claims(edit)))
            #expect(await failureCode { try await discover(edge) } == nil, "\(name)")
        }
        let rejected: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("another hostname", { $0["hostname"] = .string("other.example.com") }),
            ("hostname with a port", { $0["hostname"] = .string("gateway.example.com:443") }),
            ("no hostname", { $0["hostname"] = nil }),
            ("type app", { $0["type"] = .string("app") }), ("no type", { $0["type"] = nil }),
            ("empty aud", { $0["aud"] = .string("") }), ("no aud", { $0["aud"] = nil }),
            ("aud array", { $0["aud"] = .array([.string(AccessSignInFixture.audience)]) }),
            ("513-byte aud", { $0["aud"] = .string(String(repeating: "a", count: 513)) }),
            ("aud with a line break", { $0["aud"] = .string("aud\r\nX-Injected: 1") }),
            ("issued 24 h 1 s ago", { $0["iat"] = .number(now - 86_401) }),
            ("issued 5 min 1 s ahead", { $0["iat"] = .number(now + 301) }),
            ("iat 0", { $0["iat"] = .number(0) }), ("negative iat", { $0["iat"] = .number(-1) }),
            ("no iat", { $0["iat"] = nil }), ("iat as a string", { $0["iat"] = .string(String(Int(now))) }),
        ]
        for (name, edit) in rejected {
            let edge = Fixture.edge(metadata: try Fixture.metadata(claims: claims(edit)))
            #expect(await failureCode { try await discover(edge) } == "ACCESS_METADATA_INVALID", "\(name)")
        }
    }

    @Test func fedRAMPAndFixtureTeamDomainsServeTheirOwnKeys() async throws {
        let fed = Fixture.edge(metadata: try Fixture.metadata(claims: claims { $0["auth_domain"] = .string("team.fed.cloudflareaccess.com") }))
        #expect(try await discover(fed).authDomain == "team.fed.cloudflareaccess.com")
        #expect(await fed.requests.last?.url?.absoluteString == "https://team.fed.cloudflareaccess.com/cdn-cgi/access/certs")

        let origin = try #require(URL(string: "http://127.0.0.1:61234"))
        let endpoints = try #require(CloudflareAccessEndpoints.loopbackFixture(origin))
        let fixture = Fixture.edge(metadata: try Fixture.metadata(claims: claims { $0["hostname"] = .string("127.0.0.1") }))
        let app = try await discover(fixture, endpoint: try #require(URL(string: "ws://127.0.0.1:61234/")), endpoints: endpoints)
        #expect(app == CloudflareAccessApplication(url: try #require(URL(string: "http://127.0.0.1:61234/")),
                                                   authDomain: "team.cloudflareaccess.com", audience: AccessSignInFixture.audience))
        #expect(await fixture.requests.map(\.url?.absoluteString) == ["http://127.0.0.1:61234/", "http://127.0.0.1:61234/cdn-cgi/access/certs"])
    }

    @Test func discoveryNeedsAUsableGatewayURL() async throws {
        let edge = ScriptedFetch([.status(200)])
        #expect(await failureCode { try await discover(edge, endpoint: try #require(URL(string: "ws://gateway.example.com/"))) } == "INSECURE_URL")
        #expect(await edge.requests.isEmpty)
    }

    @Test func cancellingDiscoveryEndsWithCancellationError() async {
        let task = Task {
            try await CloudflareAccessSignIn.discover(Fixture.endpoint, now: Fixture.now) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: The live transport

    @Test func liveRequestsStoreNothingAndFollowNoRedirect() {
        let session = CloudflareAccessSignIn.liveSession(timeout: 7)
        defer { session.invalidateAndCancel() }
        #expect(session.delegate is InboundMediaRedirectRefusal)
        let configuration = session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 7)
        #expect(configuration.timeoutIntervalForResource == 7)
    }

    @Test func liveReadsStopOneBytePastTheLimit() async throws {
        func bytes(_ count: Int) -> AsyncStream<UInt8> {
            AsyncStream { continuation in
                for index in 0..<count { continuation.yield(UInt8(index)) }
                continuation.finish()
            }
        }
        #expect(try await CloudflareAccessSignIn.readBody(bytes(10), maxBytes: 3) == Data([0, 1, 2, 3]))
        #expect(try await CloudflareAccessSignIn.readBody(bytes(3), maxBytes: 3) == Data([0, 1, 2]))
        #expect(try await CloudflareAccessSignIn.readBody(bytes(5), maxBytes: 0) == Data([0]))
        #expect(try await CloudflareAccessSignIn.readBody(bytes(0), maxBytes: 0) == Data())
    }
}
