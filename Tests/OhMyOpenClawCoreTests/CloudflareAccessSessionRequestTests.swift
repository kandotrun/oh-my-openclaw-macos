import CryptoKit
import Foundation
import Testing
@testable import OhMyOpenClawCore

private typealias Fixture = AccessSessionFixture
private let chat = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Photos")
private let photo = InboundMediaReference(source: "media://inbound/photo.png", messageID: "durable-message")!

private func accessHeaders(_ request: URLRequest) -> [String: String] {
    (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased().hasPrefix("cf-access") || $0.key.lowercased() == "cookie" }
}

@Suite("Cloudflare Access sessions on Gateway requests")
struct CloudflareAccessSessionRequestTests {
    @Test func upgradeCarriesOnlyTheSessionWhenOneIsSaved() throws {
        let endpoint = try #require(URL(string: "wss://gateway.example.com/openclaw"))
        let signedIn = GatewayClient.upgradeRequest(endpoint, credentials: GatewayCredentials(token: "gateway-token", accessSession: Fixture.session))
        #expect(accessHeaders(signedIn) == ["Cf-Access-Token": Fixture.appToken])
        #expect(signedIn.url == endpoint)
        let both = GatewayClient.upgradeRequest(endpoint, credentials: GatewayCredentials(access: Fixture.serviceToken, accessSession: Fixture.session))
        #expect(accessHeaders(both) == ["Cf-Access-Token": Fixture.appToken])
        let serviceToken = GatewayClient.upgradeRequest(endpoint, credentials: GatewayCredentials(access: Fixture.serviceToken))
        #expect(accessHeaders(serviceToken) == ["CF-Access-Client-Id": "client.access", "CF-Access-Client-Secret": "client-secret"])
        #expect(accessHeaders(GatewayClient.upgradeRequest(endpoint, credentials: GatewayCredentials(token: "gateway-token"))).isEmpty)
    }

    @Test func imageAndAttachmentRequestsCarryTheSession() throws {
        let endpoint = try #require(URL(string: "wss://gateway.example.com"))
        let metadata = try GatewayInboundMediaLoader.metadataRequest(photo, session: chat, endpoint: endpoint, deviceToken: "device", access: Fixture.session)
        let bytes = try GatewayInboundMediaLoader.bytesRequest(photo, session: chat, endpoint: endpoint, mediaTicket: "ticket", access: Fixture.session)
        let download = GatewayArtifactLoader.downloadRequest(try #require(URL(string: "https://gateway.example.com/api/artifacts/download/1")), access: Fixture.session)
        for request in [metadata, bytes, download] {
            #expect(accessHeaders(request) == ["Cf-Access-Token": Fixture.appToken])
        }
    }

    @Test func imageLoadSendsTheSessionWithBothRequests() async throws {
        let fetch = RecordingFetch()
        let data = try await GatewayInboundMediaLoader.load(photo, session: chat, endpoint: try #require(URL(string: "wss://gateway.example.com")),
                                                            deviceToken: "paired-device-token", access: Fixture.session) { request, _ in
            try await fetch.fetch(request)
        }
        #expect(data == Data([1, 2, 3]))
        let requests = await fetch.requests
        #expect(requests.count == 2)
        #expect(requests.map(accessHeaders) == [["Cf-Access-Token": Fixture.appToken], ["Cf-Access-Token": Fixture.appToken]])
    }

    @Test func connectWithASessionPresentsNoSavedDeviceToken() throws {
        let identity = try DeviceIdentity(privateKeyData: Data(repeating: 7, count: 32))
        let cases: [(GatewayCredentials, auth: [String: JSONValue], signed: String)] = [
            (GatewayCredentials(deviceToken: "device-before-sign-in", scopes: ["operator.read"], accessSession: Fixture.session), [:], ""),
            (GatewayCredentials(bootstrapToken: "bootstrap", deviceToken: "device-before-sign-in", scopes: ["operator.read"], accessSession: Fixture.session),
             ["bootstrapToken": .string("bootstrap")], "bootstrap"),
            (GatewayCredentials(token: "gateway-token", deviceToken: "device-before-sign-in", scopes: ["operator.read"], accessSession: Fixture.session),
             ["token": .string("gateway-token")], "gateway-token"),
            // Without a session the saved device token still authenticates the paired device.
            (GatewayCredentials(deviceToken: "paired-device", scopes: ["operator.read"], access: Fixture.serviceToken), ["token": .string("paired-device")], "paired-device"),
            (GatewayCredentials(deviceToken: "paired-device", scopes: ["operator.read"]), ["token": .string("paired-device")], "paired-device"),
        ]
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(base64URL: identity.publicKeyBase64URL)))
        for (credentials, auth, signed) in cases {
            let params = try GatewayClient.connectParams(credentials: credentials, identity: identity, clientIdentity: GatewayClientIdentity(),
                                                         nonce: "challenge-nonce", signedAt: 1_800_000_000_000)
            #expect(params["auth"] == .object(auth))
            #expect(params["scopes"] == .array([.string("operator.read")]))
            // The device proof signs the same token the connect presents, so the Gateway can verify it.
            let payload = "v2|\(identity.deviceID)|gateway-client|ui|operator|operator.read|1800000000000|\(signed)|challenge-nonce"
            let signature = try #require(params["device"]["signature"].stringValue.flatMap { Data(base64URL: $0) })
            #expect(key.isValidSignature(signature, for: Data(payload.utf8)), "\(signed)")
            #expect(params["device"]["nonce"] == .string("challenge-nonce"))
        }
    }

    @Test func connectParamsKeepTheirShape() throws {
        let identity = try DeviceIdentity(privateKeyData: Data(repeating: 7, count: 32))
        let params = try GatewayClient.connectParams(credentials: GatewayCredentials(password: "secret-password"), identity: identity,
                                                     clientIdentity: GatewayClientIdentity(), nonce: "n", signedAt: 123)
        #expect(params["minProtocol"] == .number(4) && params["maxProtocol"] == .number(4))
        #expect(params["client"]["id"] == .string("gateway-client"))
        #expect(params["client"]["instanceId"] == .string(identity.deviceID))
        #expect(params["role"] == .string("operator"))
        #expect(params["scopes"] == .array(GatewayClient.defaultScopes.map(JSONValue.string)))
        #expect(params["auth"] == .object(["password": .string("secret-password")]))
        #expect(params["device"]["id"] == .string(identity.deviceID))
    }

    @Test func accessRedirectAsksToSignInAgainWhenASessionWasSent() throws {
        let gateway = try #require(URL(string: "https://gateway.example.com/"))
        let login = try #require(HTTPURLResponse(url: gateway, statusCode: 302, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/gateway.example.com?token=leak"]))
        let expired = try #require(GatewayClient.upgradeRefusal(login, credentials: GatewayCredentials(accessSession: Fixture.session)))
        #expect(expired.code == "ACCESS_REQUIRED")
        #expect(expired.message == "Cloudflare Access のサインインが無効になりました。ブラウザでもう一度サインインしてください。")
        for credentials in [GatewayCredentials(), GatewayCredentials(token: "gateway-token"), GatewayCredentials(access: Fixture.serviceToken)] {
            let required = try #require(GatewayClient.upgradeRefusal(login, credentials: credentials))
            #expect(required.code == "ACCESS_REQUIRED")
            #expect(required.message == "Cloudflare Access のログインを求められました。ブラウザでサインインするか、Access のサービストークン（Client ID と Client Secret）を入力してください。")
        }
        // UITests/DemoSmokeTests.swift finds the refusal by this text.
        #expect(GatewayClient.upgradeRefusal(login)?.message.contains("Cloudflare Access のログイン") == true)
        for message in [expired.message, GatewayClient.upgradeRefusal(login)?.message ?? ""] {
            #expect(!message.contains("cloudflareaccess.com") && !message.contains("leak") && !message.contains(Fixture.appToken))
        }
        let forbidden = try #require(HTTPURLResponse(url: gateway, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:]))
        #expect(GatewayClient.upgradeRefusal(forbidden, credentials: GatewayCredentials(accessSession: Fixture.session))?.code == "UPGRADE_REFUSED")
    }

    @Test func aConnectRefusedForWantOfAPersonAsksForSignIn() {
        let missingUser = GatewayFailure(code: "INVALID_REQUEST", message: "unauthorized: trusted proxy user missing", details: .object([
            "code": .string("AUTH_UNAUTHORIZED"), "authReason": .string("trusted_proxy_user_missing"), "canRetryWithDeviceToken": .bool(false),
        ]))
        let verifiedUserRequired = GatewayFailure(code: "NOT_PAIRED", message: "operator role policies require a verified user identity",
                                                  details: .object(["code": .string("AUTH_VERIFIED_USER_REQUIRED")]))
        let serviceTokenMessage = "この Gateway は Cloudflare Access のサービストークンでは操作できません。ブラウザで本人のアカウントにサインインしてください。"
        let nothingSentMessage = "この Gateway を操作するには Cloudflare Access のサインインが必要です。ブラウザで本人のアカウントにサインインしてください。"
        let unsigned: [(GatewayCredentials, String)] = [
            (GatewayCredentials(access: Fixture.serviceToken), serviceTokenMessage),
            (GatewayCredentials(bootstrapToken: "bootstrap", access: Fixture.serviceToken), serviceTokenMessage),
            (GatewayCredentials(deviceToken: "leftover-device", access: Fixture.serviceToken), serviceTokenMessage),
            (GatewayCredentials(deviceToken: "leftover-device"), nothingSentMessage),
            (GatewayCredentials(), nothingSentMessage),
        ]
        for (credentials, message) in unsigned {
            for failure in [missingUser, verifiedUserRequired] {
                let mapped = GatewayClient.accessFailure(failure, credentials: credentials)
                #expect(mapped.code == "ACCESS_IDENTITY_REQUIRED")
                #expect(mapped.message == message)
                // No pairing request ID survives, so the refusal is never shown as a pairing.
                #expect(mapped.details == .null)
            }
        }
        // With a session sent, the Gateway's own answer stands.
        for failure in [missingUser, verifiedUserRequired] {
            let kept = GatewayClient.accessFailure(failure, credentials: GatewayCredentials(accessSession: Fixture.session))
            #expect(kept.code == failure.code && kept.message == failure.message && kept.details == failure.details)
        }
        let unrelated = [
            GatewayFailure(code: "NOT_PAIRED", message: "pairing required", details: .object(["code": .string("PAIRING_REQUIRED"), "requestId": .string("request-1")])),
            GatewayFailure(code: "NOT_PAIRED", message: "pairing required"),
            GatewayFailure(code: "INVALID_REQUEST", message: "unauthorized", details: .object(["authReason": .string("token_mismatch")])),
            GatewayFailure(code: "INVALID_REQUEST", message: "AUTH_VERIFIED_USER_REQUIRED", details: .object(["code": .string("AUTH_VERIFIED_USER_REQUIRED")])),
            GatewayFailure(code: "ACCESS_REQUIRED", message: "login"),
        ]
        for failure in unrelated {
            let kept = GatewayClient.accessFailure(failure, credentials: GatewayCredentials(access: Fixture.serviceToken))
            #expect(kept.code == failure.code && kept.message == failure.message && kept.details == failure.details)
        }
    }
}

/// Answers the image metadata request, then the bytes request.
private actor RecordingFetch {
    var requests: [URLRequest] = []

    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let metadata = requests.count == 1
        let data = metadata ? try JSONEncoder().encode(JSONValue.object([
            "available": .bool(true), "mimeType": .string("image/png"), "sizeBytes": .number(3),
            "mediaTicket": .string("synthetic-ticket"), "mediaTicketExpiresAt": .string("2099-01-01T00:00:00.000Z"),
        ])) : Data([1, 2, 3])
        let headers = ["Content-Type": metadata ? "application/json" : "image/png"]
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}
