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

/// Holds one history read so a notification can arrive while its stale
/// snapshot is still on the wire.
private actor HeldHistoryGateway: GatewayServing {
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private var transcript: [JSONValue] = [.object(["id": .string("first"), "role": .string("assistant"), "content": .string("First")])]
    private var holdNext = false
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

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
        let snapshot = transcript
        if holdNext {
            holdNext = false; holding = true
            started?.resume(); started = nil
            await withCheckedContinuation { held = $0 }
        }
        return .object(["sessionId": .string(collapsedSide.sessionID!), "messages": .array(snapshot)])
    }
    func holdNextHistoryRead() { holdNext = true }
    func waitUntilHolding() async {
        if holding { return }
        await withCheckedContinuation { started = $0 }
    }
    func commit(_ text: String) {
        transcript.append(.object(["id": .string(text), "role": .string("assistant"), "content": .string(text)]))
    }
    func releaseHeldRead() { holding = false; held?.resume(); held = nil }
    func emitSessionsChanged(_ payload: [String: JSONValue]) {
        continuation?.yield(GatewayEvent(name: "sessions.changed", payload: .object(payload)))
    }
}

@Test @MainActor func collapsedNotificationDuringAnInFlightReadStillRefetches() async throws {
    let gateway = HeldHistoryGateway()
    var store = ConversationStore()
    store.upsertSession(collapsedMain); store.upsertSession(collapsedSide)
    store.selectedID = collapsedSide.id
    let app = AppModel(service: gateway, initialStore: store)
    await app.establishConnection()

    await gateway.holdNextHistoryRead()
    let staleRead = Task { try await app.refreshHistory(for: collapsedSide) }
    await gateway.waitUntilHolding()
    await gateway.commit("Committed while reading")
    await gateway.emitSessionsChanged([
        "sessionKey": .string(collapsedSide.key), "agentId": .string("a"), "phase": .string("message"),
        "session": .object(["key": .string(collapsedSide.key), "agentId": .string("a"), "sessionId": .string(collapsedSide.sessionID!), "label": .string("Handled")]),
    ])
    // The label proves the handler ran before the stale snapshot is released.
    let handledBy = ContinuousClock.now + .seconds(1)
    while app.sessions.first(where: { $0.id == collapsedSide.id })?.title != "Handled", ContinuousClock.now < handledBy { await Task.yield() }
    #expect(app.sessions.first(where: { $0.id == collapsedSide.id })?.title == "Handled")

    await gateway.releaseHeldRead()
    try await staleRead.value
    let deadline = ContinuousClock.now + .seconds(1)
    while !app.messages.contains(where: { $0.text == "Committed while reading" }), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(app.messages.contains { $0.text == "Committed while reading" })
    await app.disconnect()
}
