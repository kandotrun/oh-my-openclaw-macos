#if os(macOS)
import Foundation
import Testing
@testable import OhMyOpenClawCore

@Suite("Loopback WebSocket contract")
struct GatewayIntegrationTests {
    @Test("Challenge handshake, multiplexed RPCs, and streamed completion")
    func websocketRoundTrip() async throws {
        let fixture = Process()
        let output = Pipe()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/gateway-fixture.py")
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [script.path]
        fixture.standardOutput = output
        fixture.standardError = FileHandle.standardError
        try fixture.run()
        defer { fixture.terminate(); fixture.waitUntilExit() }
        let portData = output.fileHandleForReading.availableData
        let port = try #require(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let client = GatewayClient(endpoint: URL(string: "ws://127.0.0.1:\(port)")!, credentials: GatewayCredentials(token: "synthetic-bootstrap"), identity: DeviceIdentity())
        let stream = await client.events()
        let hello = try await client.connect()
        #expect(hello.payload["protocol"].intValue == 4)
        #expect(hello.payload["auth"]["deviceToken"].stringValue == "synthetic-fixture-device-token")

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask { try await client.request(method: "health", params: .object([:]))["fixture"].boolValue == true }
            }
            for try await valid in group { #expect(valid) }
        }

        for selectors: [String: JSONValue] in [
            ["sessionId": .string("fixture-main")],
            ["sessionId": .string("fixture-main"), "offset": .number(100)],
        ] {
            var params = selectors
            params["sessionKey"] = .string("agent:fixture:main")
            do {
                _ = try await client.request(method: "chat.history", params: .object(params))
                Issue.record("A physical history selector without a message anchor must be rejected")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "INVALID_REQUEST")
                #expect(failure.message == "sessionId requires messageId")
            }
        }
        do {
            _ = try await client.request(method: "chat.history", params: .object([
                "sessionKey": .string("agent:fixture:main"), "sessionId": .string("fixture-main"),
                "messageId": .string("anchor"), "offset": .number(100),
            ]))
            Issue.record("Anchored history cannot be combined with offset paging")
        } catch let failure as GatewayFailure {
            #expect(failure.code == "INVALID_REQUEST")
            #expect(failure.message == "offset and messageId cannot be used together")
        }
        for offset: JSONValue? in [nil, .number(100)] {
            var params: [String: JSONValue] = ["sessionKey": .string("agent:fixture:main"), "limit": .number(100)]
            if let offset { params["offset"] = offset }
            let history = try await client.request(method: "chat.history", params: .object(params))
            #expect(history["sessionId"].stringValue == "fixture-main")
            #expect(history["messages"].arrayValue == [])
        }

        let completion = Task { () throws -> [GatewayEvent] in
            try await withThrowingTaskGroup(of: [GatewayEvent].self) { group in
                group.addTask {
                    var received: [GatewayEvent] = []
                    for await event in stream {
                        received.append(event)
                        if event.name == "chat", event.payload["state"].stringValue == "final" { return received }
                    }
                    throw GatewayFailure(code: "TEST_STREAM_ENDED", message: "Stream ended before final")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw GatewayFailure(code: "TEST_TIMEOUT", message: "Fixture stream timed out")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }
        let ack = try await client.request(method: "chat.send", params: .object([
            "sessionKey": .string("agent:fixture:main"), "message": .string("hello"), "idempotencyKey": .string("fixture-run"),
        ]))
        #expect(ack["runId"].stringValue == "fixture-run")
        let events = try await completion.value
        #expect(events.filter { $0.name == "chat" && $0.payload["state"].stringValue == "delta" }.compactMap { $0.payload["deltaText"].stringValue }.joined() == "This is a synthetic WebSocket response.")
        #expect(events.contains { $0.name == "agent" && $0.payload["stream"].stringValue == "tool" })
        #expect(events.last?.payload["runId"].stringValue == "fixture-run")
        do {
            _ = try await client.request(method: "fixture.close", params: .object([:]))
            Issue.record("A socket close must fail its pending RPC")
        } catch let failure as GatewayFailure {
            #expect(failure.code == "CONNECTION_LOST")
        }
        await client.disconnect()
    }

    @Test("A Gateway behind Cloudflare Access admits only upgrades that carry the service token")
    func accessProtectedUpgrade() async throws {
        let fixture = Process()
        let output = Pipe()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/gateway-fixture.py")
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [script.path, "--access"]
        fixture.standardOutput = output
        fixture.standardError = FileHandle.standardError
        try fixture.run()
        defer { fixture.terminate(); fixture.waitUntilExit() }
        let portData = output.fileHandleForReading.availableData
        let port = try #require(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let endpoint = URL(string: "ws://127.0.0.1:\(port)")!

        let blocked = GatewayClient(endpoint: endpoint, credentials: GatewayCredentials(token: "synthetic-bootstrap"), identity: DeviceIdentity())
        do {
            _ = try await blocked.connect()
            Issue.record("An upgrade without the service token must not connect")
        } catch let failure as GatewayFailure {
            #expect(failure.code == "ACCESS_REQUIRED")
        }

        let token = try #require(CloudflareAccessToken(clientID: "fixture-access.access", clientSecret: "fixture-access-secret"))
        let admitted = GatewayClient(endpoint: endpoint, credentials: GatewayCredentials(token: "synthetic-bootstrap", access: token), identity: DeviceIdentity())
        let hello = try await admitted.connect()
        #expect(hello.payload["protocol"].intValue == 4)
        await admitted.disconnect()
    }
}
#endif
