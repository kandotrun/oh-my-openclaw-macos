import Foundation
import Observation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private let identityMain = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "a-physical", title: "Main", isMain: true)
private let identitySide = ChatSession(key: "agent:b:side", agentID: "b", sessionID: "b-physical", title: "Side")

@MainActor private final class IdentityObservationFlag { var changed = false }

private func identityStore(selected: ChatSession) -> ConversationStore {
    var store = ConversationStore()
    store.upsertSession(identityMain); store.upsertSession(identitySide)
    store.selectedID = selected.id
    return store
}

private actor IdentityGateway: GatewayServing {
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private var pauseAgent: String?
    private var paused: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didPause = false
    var calls: [(String, JSONValue)] = []
    var names = ["a": "Agent Alpha", "b": "Agent Beta"]

    func connect() async throws -> GatewayHello {
        GatewayHello(payload: .object(["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("a"), "mainSessionKey": .string(identityMain.key),
        ])])]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let stream = AsyncStream<GatewayEvent>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }
    func disconnect() async { continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append((method, params))
        switch method {
        case "agent.identity.get":
            let agent = params["agentId"].stringValue ?? ""
            let name = names[agent] ?? "Assistant"
            if pauseAgent == agent {
                pauseAgent = nil; didPause = true
                started?.resume(); started = nil
                await withCheckedContinuation { paused = $0 }
            }
            return .object(["agentId": .string(agent), "name": .string(name), "nameSource": .string("identity")])
        case "agents.identity.get":
            throw GatewayFailure(code: "INVALID_REQUEST", message: "unknown method: agents.identity.get")
        case "chat.history":
            let session = params["sessionKey"].stringValue == identitySide.key ? identitySide : identityMain
            return .object(["sessionId": .string(session.sessionID!), "messages": .array([])])
        default: return .object([:])
        }
    }
    func pauseIdentity(for agent: String) { pauseAgent = agent; didPause = false }
    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseIdentity() { paused?.resume(); paused = nil }
    func changeName(_ name: String, for agent: String) {
        names[agent] = name
        continuation?.yield(GatewayEvent(name: "agent.identity.changed", payload: .object(["agentId": .string(agent)])))
    }
}

@Test @MainActor func connectionLoadsTheSelectedAgentsConfiguredNameUsingTheRealRPC() async {
    let gateway = IdentityGateway()
    let app = AppModel(service: gateway, initialStore: identityStore(selected: identitySide))
    await app.establishConnection()
    #expect(app.connectionState == .connected)
    #expect(app.agentName == "Agent Beta")
    let calls = await gateway.calls
    #expect(calls.contains { $0.0 == "agent.identity.get" && $0.1["agentId"].stringValue == "b" })
    #expect(!calls.contains { $0.0 == "agents.identity.get" })
    await app.disconnect()
    #expect(app.agentName == "エージェント")
}

@Test @MainActor func aDelayedIdentityCannotReplaceTheNewlySelectedAgentsName() async {
    let gateway = IdentityGateway()
    let app = AppModel(service: gateway, initialStore: identityStore(selected: identityMain))
    await gateway.pauseIdentity(for: "a")
    let old = Task { await app.selectSession(identityMain) }
    await gateway.waitUntilPaused()
    await app.selectSession(identitySide)
    #expect(app.agentName == "Agent Beta")
    await gateway.releaseIdentity()
    await old.value
    #expect(app.agentName == "Agent Beta")
    await app.disconnect()
}

@Test @MainActor func identityChangeRefreshesTheNameWithoutReconnecting() async {
    let gateway = IdentityGateway()
    let app = AppModel(service: gateway, initialStore: identityStore(selected: identityMain))
    await app.establishConnection()
    #expect(app.agentName == "Agent Alpha")
    let observed = IdentityObservationFlag()
    withObservationTracking { _ = app.agentName } onChange: {
        Task { @MainActor in observed.changed = true }
    }
    await gateway.changeName("Renamed Agent", for: "a")
    let deadline = ContinuousClock.now + .seconds(1)
    while (app.agentName != "Renamed Agent" || !observed.changed), ContinuousClock.now < deadline { await Task.yield() }
    #expect(app.agentName == "Renamed Agent")
    #expect(observed.changed)
    #expect(app.connectionState == .connected)
    await app.disconnect()
}

@Test @MainActor func disconnectDiscardsAnInFlightIdentityResponse() async {
    let gateway = IdentityGateway()
    let app = AppModel(service: gateway, initialStore: identityStore(selected: identityMain))
    await gateway.pauseIdentity(for: "a")
    let old = Task { await app.selectSession(identityMain) }
    await gateway.waitUntilPaused()
    await app.disconnect()
    await gateway.releaseIdentity()
    await old.value
    #expect(app.agentName == "エージェント")
    #expect(app.connectionState == .disconnected)
}

/// An agent can open a session that belongs to another agent; its opening row names the opener.
@Test @MainActor func agentOpeningsUseTheOpenersKnownName() async throws {
    let gateway = IdentityGateway()
    let app = AppModel(service: gateway, initialStore: identityStore(selected: identityMain))
    await app.establishConnection()
    await app.selectSession(identitySide)
    #expect(app.agentName == "Agent Beta")
    #expect(app.agentName(for: "a") == "Agent Alpha")
    #expect(app.agentName(for: "unknown") == "unknown")
    await app.disconnect()
}
