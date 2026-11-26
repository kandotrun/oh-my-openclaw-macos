import Foundation
import Testing
@testable import OhMyOpenClawCore

struct TransportEndpointTests {
    @Test func endpointsPreserveSecureOriginAndPath() throws {
        #expect(try GatewayEndpoint.parse(" https://EXAMPLE.invalid/gateway ").absoluteString == "wss://example.invalid/gateway")
        #expect(try GatewayEndpoint.parse("wss://example.invalid:8443").absoluteString == "wss://example.invalid:8443/")
        #expect(try GatewayEndpoint.parse("ws://127.0.0.1:18888").scheme == "ws")
        #expect(try GatewayEndpoint.parse("ws://[::1]:18888").scheme == "ws")
    }

    @Test(arguments: ["ws://example.invalid", "http://192.168.1.1", "wss://secret@example.invalid", "wss://example.invalid?token=secret", "wss://example.invalid#secret", "file:///tmp/gateway", "wss://", "example.invalid"])
    func rejectsUnsafeOrAmbiguousURL(_ text: String) {
        #expect(throws: GatewayFailure.self) { try GatewayEndpoint.parse(text) }
    }

    @Test func setupCodeDecodesWithoutDisclosingCredential() throws {
        let json: JSONValue = .object(["url": .string("wss://example.invalid"), "bootstrapToken": .string("test-bootstrap"), "expiresAtMs": .number(Date().timeIntervalSince1970 * 1000 + 120_000).roundedToInteger])
        let code = try JSONEncoder().encode(json).base64URL
        let decoded = try GatewayEndpoint.decodeSetupCode("oc-pair://" + code)
        #expect(decoded.url.absoluteString == "wss://example.invalid/")
        #expect(decoded.bootstrapToken == "test-bootstrap")
        #expect(decoded.expiresAtMs != nil)
    }

    @Test func rejectsExpiredMalformedAndPinnedSetupCodes() throws {
        let cases: [JSONValue] = [
            .object(["url": .string("wss://example.invalid"), "bootstrapToken": .string("test"), "expiresAtMs": .number(0)]),
            .object(["url": .string("wss://example.invalid"), "bootstrapToken": .string("test"), "expiresAtMs": .string("tomorrow")]),
            .object(["url": .string("wss://example.invalid"), "bootstrapToken": .string("test"), "tlsFingerprint": .string("test-pin")]),
            .object(["url": .string("ws://example.invalid"), "bootstrapToken": .string("test")]),
            .object(["url": .string("wss://example.invalid"), "bootstrapToken": .string("")]),
        ]
        for value in cases {
            let code = try JSONEncoder().encode(value).base64URL
            #expect(throws: GatewayFailure.self) { try GatewayEndpoint.decodeSetupCode(code) }
        }
        #expect(throws: GatewayFailure.self) { try GatewayEndpoint.decodeSetupCode("not a code") }
    }

    @Test func requestsCannotRunBeforeAuthenticatedHello() async throws {
        let client = GatewayClient(endpoint: try GatewayEndpoint.parse("wss://example.invalid"), credentials: .init(), identity: .init())
        do {
            _ = try await client.request(method: "chat.send", params: .object([:]))
            Issue.record("A request escaped before hello-ok")
        } catch let failure as GatewayFailure {
            #expect(failure.code == "NOT_CONNECTED")
        }
        await client.disconnect()
    }
}

private extension JSONValue {
    var roundedToInteger: JSONValue { .number(numberValue!.rounded()) }
}
