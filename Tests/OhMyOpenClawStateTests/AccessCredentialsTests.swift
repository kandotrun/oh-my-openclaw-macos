import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

/// A Gateway that pairs this device on connect by issuing a device token.
private actor PairingGateway: GatewayServing {
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    func connect() async throws -> GatewayHello {
        GatewayHello(payload: .object([
            "auth": .object(["deviceToken": .string("issued-device-token")]),
            "snapshot": .object(["sessionDefaults": .object(["defaultAgentId": .string("a"), "mainSessionKey": .string("agent:a:main")])]),
        ]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let channel = AsyncStream<GatewayEvent>.makeStream()
        continuation = channel.continuation
        return channel.stream
    }
    func disconnect() async { continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        method == "chat.history" ? .object(["sessionId": .string("physical"), "messages": .array([])]) : .object([:])
    }
}

private actor MemoryDisk: ConversationPersisting {
    func load() async throws -> ConversationStore { ConversationStore() }
    func save(_ state: ConversationStore, revision: Int) async throws {}
}

@MainActor private final class MemoryKeychain {
    var values: [String: GatewayCredentials] = [:]
    var made: [GatewayCredentials] = []
    var access: GatewayConnectionAccess {
        GatewayConnectionAccess(read: { self.values[$0] }, write: { self.values[$1] = $0 }, delete: { self.values[$0] = nil },
                                makeService: { _, credentials in self.made.append(credentials); return PairingGateway() })
    }
}

private let serviceToken = CloudflareAccessToken(clientID: "client.access", clientSecret: "client-secret")!
private let protectedGateway = "wss://gateway.example.com"

@Test @MainActor func serviceTokenIsSavedAndOutlivesThePairedDeviceToken() async throws {
    let keychain = MemoryKeychain()
    let app = AppModel(persistenceFactory: { _ in MemoryDisk() }, profileRepository: TestGatewayProfileRepository(), connectionAccess: keychain.access)
    await app.connect(urlText: protectedGateway, secret: "gateway-token", password: false, setupCode: "", access: serviceToken)
    #expect(app.connectionState == .connected)
    #expect(keychain.made.last?.access == serviceToken)
    let saved = try #require(keychain.values.values.first)
    #expect(saved.deviceToken == "issued-device-token")
    #expect(saved.access == serviceToken)
    await app.disconnect()
}

@Test @MainActor func reenteringTheGatewayTokenKeepsTheSavedServiceToken() async throws {
    let keychain = MemoryKeychain()
    let app = AppModel(persistenceFactory: { _ in MemoryDisk() }, profileRepository: TestGatewayProfileRepository(), connectionAccess: keychain.access)
    await app.connect(urlText: protectedGateway, secret: "gateway-token", password: false, setupCode: "", access: serviceToken)
    await app.disconnect()
    await app.connect(urlText: protectedGateway, secret: "rotated-token", password: false, setupCode: "")
    #expect(keychain.made.last?.token == "rotated-token")
    #expect(keychain.made.last?.access == serviceToken)
    await app.disconnect()
}
