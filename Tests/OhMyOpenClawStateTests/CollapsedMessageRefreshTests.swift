import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

// Contract: OpenClaw docs/gateway/protocol/rpc-bootstrap-and-events.md. Queued
// message notifications can collapse into one sessions.changed event with
// phase "message" and no message, messageId, or messageSeq; clients refetch.

private let collapsedMain = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "a-physical", title: "Main", isMain: true)
private let collapsedSide = ChatSession(key: "agent:a:side", agentID: "a", sessionID: "side-physical", title: "Side")

private actor CollapsedNotificationGateway: GatewayServing {
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private(set) var historyKeys: [String] = []

    func connect() async throws -> GatewayHello {
        GatewayHello(payload: .object(["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("a"), "mainSessionKey": .string(collapsedMain.key),
        ])])]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let stream = AsyncStream<GatewayEvent>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }
    func disconnect() async { continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "chat.history" else { return .object([:]) }
        let key = params["sessionKey"].stringValue ?? ""
        historyKeys.append(key)
        let session = key == collapsedSide.key ? collapsedSide : collapsedMain
        return .object(["sessionId": .string(session.sessionID!), "messages": .array([])])
    }
    func emitSessionsChanged(_ payload: [String: JSONValue]) {
        continuation?.yield(GatewayEvent(name: "sessions.changed", payload: .object(payload)))
    }
    func historyReads(for key: String) -> Int { historyKeys.filter { $0 == key }.count }
}

private func row(_ session: ChatSession) -> JSONValue {
    .object(["key": .string(session.key), "agentId": .string(session.agentID), "sessionId": .string(session.sessionID!)])
}

@MainActor private func connectedApp(_ gateway: CollapsedNotificationGateway) async -> AppModel {
    var store = ConversationStore()
    store.upsertSession(collapsedMain); store.upsertSession(collapsedSide)
    store.selectedID = collapsedMain.id
    let app = AppModel(service: gateway, initialStore: store)
    await app.establishConnection()
    return app
}

/// Waits past the 350 ms quiet-refresh debounce, returning early once reads reach the target.
private func historyReads(_ gateway: CollapsedNotificationGateway, key: String, reaching target: Int) async -> Int {
    let deadline = ContinuousClock.now + .milliseconds(900)
    var count = await gateway.historyReads(for: key)
    while count < target, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        count = await gateway.historyReads(for: key)
    }
    return count
}

@Test @MainActor func collapsedMessageNotificationRefetchesTheSelectedConversation() async {
    let gateway = CollapsedNotificationGateway()
    let app = await connectedApp(gateway)
    let before = await gateway.historyReads(for: collapsedMain.key)
    await gateway.emitSessionsChanged(["sessionKey": .string(collapsedMain.key), "agentId": .string("a"), "phase": .string("message"), "session": row(collapsedMain)])
    #expect(await historyReads(gateway, key: collapsedMain.key, reaching: before + 1) == before + 1)
    await app.disconnect()
}

@Test @MainActor func messageNotificationWithAMessageCursorDoesNotRefetch() async {
    let gateway = CollapsedNotificationGateway()
    let app = await connectedApp(gateway)
    let before = await gateway.historyReads(for: collapsedMain.key)
    await gateway.emitSessionsChanged(["sessionKey": .string(collapsedMain.key), "agentId": .string("a"), "phase": .string("message"), "messageId": .string("m-1"), "session": row(collapsedMain)])
    #expect(await historyReads(gateway, key: collapsedMain.key, reaching: before + 1) == before)
    await app.disconnect()
}

@Test @MainActor func collapsedNotificationForAnotherConversationDoesNotRefetch() async {
    let gateway = CollapsedNotificationGateway()
    let app = await connectedApp(gateway)
    let main = await gateway.historyReads(for: collapsedMain.key)
    let side = await gateway.historyReads(for: collapsedSide.key)
    await gateway.emitSessionsChanged(["sessionKey": .string(collapsedSide.key), "agentId": .string("a"), "phase": .string("message"), "session": row(collapsedSide)])
    #expect(await historyReads(gateway, key: collapsedSide.key, reaching: side + 1) == side)
    #expect(await gateway.historyReads(for: collapsedMain.key) == main)
    await app.disconnect()
}
