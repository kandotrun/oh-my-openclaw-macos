import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor RecoveringGateway: GatewayServing {
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private var refuseConnection = false
    func connect() async throws -> GatewayHello {
        if refuseConnection { throw GatewayFailure(code: "CONNECTION_LOST", message: "Synthetic connection failure") }
        return GatewayHello(payload: .object(["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("a"), "mainSessionKey": .string("agent:a:main"),
        ])])]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        continuation?.finish()
        let channel = AsyncStream<GatewayEvent>.makeStream()
        continuation = channel.continuation
        return channel.stream
    }
    func request(method: String, params: JSONValue) async throws -> JSONValue { .object([:]) }
    func disconnect() async { continuation?.finish() }
    func dropConnection() { continuation?.yield(GatewayEvent(name: "client.disconnected", payload: .null)) }
    func setConnectionFailure(_ value: Bool) { refuseConnection = value }
}

@Test @MainActor func successfulConnectionRestoresRecoveryButFailedConnectionDoesNot() async throws {
    let gateway = RecoveringGateway()
    let app = AppModel(service: gateway)
    await app.establishConnection()
    #expect(app.connectionState == .connected)
    await gateway.dropConnection()
    let deadline = ContinuousClock.now + .seconds(2)
    while app.connectionState == .connected && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(app.connectionState == .disconnected)
    #expect(app.attemptedAutomaticRecovery)
    await gateway.setConnectionFailure(true)
    await app.establishConnection()
    #expect(app.connectionState != .connected)
    #expect(app.attemptedAutomaticRecovery)
    await gateway.setConnectionFailure(false)
    await app.establishConnection()
    #expect(app.connectionState == .connected)
    #expect(!app.attemptedAutomaticRecovery)
    await gateway.dropConnection()
    let secondDeadline = ContinuousClock.now + .seconds(2)
    while app.connectionState == .connected && ContinuousClock.now < secondDeadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(app.connectionState == .disconnected)
    #expect(app.attemptedAutomaticRecovery)
    await app.disconnect()
}
