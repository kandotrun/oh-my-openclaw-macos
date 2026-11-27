import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor SavedStates: ConversationPersisting {
    private(set) var writes: [ConversationStore] = []
    func load() async throws -> ConversationStore { ConversationStore() }
    func save(_ state: ConversationStore, revision: Int) async throws { writes.append(state) }
}

/// History with one `swift test` call whose output must stay in memory, and an older page with a read.
private actor ToolHistoryGateway: GatewayServing {
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    func connect() async throws -> GatewayHello {
        GatewayHello(payload: .object(["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("a"), "mainSessionKey": .string("agent:a:main"),
        ])])]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let channel = AsyncStream<GatewayEvent>.makeStream()
        continuation = channel.continuation
        return channel.stream
    }
    func disconnect() async { continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "chat.history" else { return .object([:]) }
        if params["offset"].intValue != nil {
            return .object(["sessionId": .string("physical"), "hasMore": .bool(false), "messages": .array([
                .object(["role": .string("assistant"), "content": .array([.object([
                    "type": .string("toolCall"), "id": .string("c0"), "name": .string("read"), "arguments": .object(["path": .string("old.swift")]),
                ])]), "__openclaw": .object(["id": .string("a0"), "runId": .string("r0")])]),
            ])])
        }
        return .object(["sessionId": .string("physical"), "hasMore": .bool(true), "messages": .array([
            .object(["role": .string("user"), "content": .string("直して"), "__openclaw": .object(["id": .string("u1")])]),
            .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string("確認します。")]),
                .object(["type": .string("toolCall"), "id": .string("c1"), "name": .string("exec"), "arguments": .object(["command": .string("swift test")])]),
            ]), "__openclaw": .object(["id": .string("a1"), "runId": .string("r1")])]),
            .object(["role": .string("toolResult"), "toolCallId": .string("c1"), "content": .array([.object(["type": .string("text"), "text": .string("secret tool output")])]),
                     "__openclaw": .object(["id": .string("t1"), "runId": .string("r1")])]),
        ])])
    }
}

@Test @MainActor func historyBuildsTheWorkLogButOnlyInMemory() async throws {
    let disk = SavedStates()
    let app = AppModel(service: ToolHistoryGateway(), initialStore: ConversationStore(), initialPersistence: disk)
    await app.establishConnection()
    let entry = try #require(app.selectedWorkLog?.entries["a1"]?.first)
    #expect(entry.summary == "swift test")
    #expect(entry.output == "secret tool output")
    #expect(app.transcriptRows.count == 3)
    let saved = try JSONEncoder().encode(try #require(await disk.writes.last))
    #expect(!String(decoding: saved, as: UTF8.self).contains("secret tool output"))
    await app.disconnect()
    #expect(app.selectedWorkLog == nil)
}

@Test @MainActor func olderHistoryAddsItsWork() async throws {
    let app = AppModel(service: ToolHistoryGateway(), initialStore: ConversationStore())
    await app.establishConnection()
    await app.loadOlderHistory()
    #expect(app.selectedWorkLog?.entries["a0"]?.first?.summary == "old.swift")
    #expect(app.selectedWorkLog?.entries["a1"]?.first?.summary == "swift test")
    await app.disconnect()
}
