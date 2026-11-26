import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private let presentationSession = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)

@Test @MainActor func cachedInternalRowsStayOutOfTheConversationWithoutRemovingRawHistory() {
    var store = ConversationStore()
    store.upsertSession(presentationSession); store.selectedID = presentationSession.id
    let publicJSON = "{\"type\":\"input_text\",\"text\":\"a user-requested example\"}"
    store.transcripts[presentationSession.id] = [
        ChatMessage(id: "user", role: .user, text: "JSONの例を見せて"),
        ChatMessage(id: "legacy-tool", role: .system, text: "legacy internal tool output"),
        ChatMessage(id: "empty", role: .assistant, text: ""),
        ChatMessage(id: "answer", role: .assistant, text: publicJSON),
    ]
    let app = AppModel(initialStore: store)
    #expect(app.messages.map(\.id) == ["user", "answer"])
    #expect(app.messages.last?.text == publicJSON)
    #expect(store.selectedMessages.count == 4)
}

private actor MixedTranscriptPages: GatewayServing {
    private(set) var offsets: [Int] = []
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "chat.history" else { return .null }
        if let offset = params["offset"].intValue {
            offsets.append(offset)
            return .object([
                "sessionId": .string("physical"), "hasMore": .bool(false),
                "messages": .array([
                    .object(["id": .string("older-tool"), "role": .string("toolResult"), "content": .string("internal result")]),
                    .object(["id": .string("older-user"), "role": .string("user"), "content": .string("以前の質問")]),
                ]),
            ])
        }
        return .object([
            "sessionId": .string("physical"), "hasMore": .bool(true),
            "messages": .array([
                .object(["id": .string("before"), "role": .string("assistant"), "content": .string("調べます。")]),
                .object(["id": .string("tool"), "role": .string("toolResult"), "content": .string("internal result")]),
                .object(["id": .string("call"), "role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "name": .string("read")])])]),
                .object(["id": .string("after"), "role": .string("assistant"), "content": .string("調査結果です。")]),
            ]),
        ])
    }
}

@Test @MainActor func hiddenToolRowsStillCountTowardHistoryPagination() async throws {
    let service = MixedTranscriptPages()
    var store = ConversationStore(); store.upsertSession(presentationSession); store.selectedID = presentationSession.id
    let app = AppModel(service: service, initialStore: store)
    try await app.refreshHistory(for: presentationSession)
    #expect(app.messages.map(\.text) == ["調べます。", "調査結果です。"])
    await app.loadOlderHistory()
    #expect(await service.offsets == [4])
    #expect(app.messages.map(\.text) == ["以前の質問", "調べます。", "調査結果です。"])
    #expect(!app.hasMoreHistory)
}
