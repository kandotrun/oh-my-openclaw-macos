import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor HistoryPages: GatewayServing {
    private(set) var calls: [JSONValue] = []
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "chat.history" else { return .object([:]) }
        calls.append(params)
        if params["sessionId"] != .null, params["messageId"] == .null {
            throw GatewayFailure(code: "INVALID_REQUEST", message: "sessionId requires messageId")
        }
        let range: Range<Int>
        if calls.count == 1 { range = 100..<200 }
        else if calls.count == 2 { range = 0..<100 }
        else if calls.count == 3 { range = 101..<201 }
        else { range = -100..<0 }
        let rows = range.map { number in
            JSONValue.object(["id": .string("message-\(number)"), "role": .string("assistant"), "content": .string("Message \(number)")])
        }
        return .object(["sessionId": .string("physical"), "messages": .array(rows), "hasMore": .bool(calls.count < 4), "nextOffset": .number(calls.count == 2 ? 200 : calls.count == 4 ? 301 : 100)])
    }
}

@Test @MainActor func recentRefreshRetainsLoadedOlderRowsAndTheirPagination() async throws {
    let service = HistoryPages()
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    let app = AppModel(service: service, initialStore: store)
    try await app.refreshHistory(for: main)
    await app.loadOlderHistory()
    let oldAnchor = try #require(app.messages.first { $0.text == "Message 50" }?.id)
    try await app.refreshHistory(for: main)
    #expect(app.messages.count == 201)
    #expect(app.messages.contains { $0.id == oldAnchor })
    #expect(app.messages.first?.text == "Message 0")
    #expect(app.messages.last?.text == "Message 200")
    await app.loadOlderHistory()
    #expect(await service.calls.last?["offset"].intValue == 201)
    #expect(app.messages.first?.text == "Message -100")
    #expect(!app.hasMoreHistory)
    #expect(await service.calls.allSatisfy { $0["sessionId"] == .null && $0["messageId"] == .null && $0["expectedSessionId"] == .null })
}

private actor ReplacedHistoryPages: GatewayServing {
    private(set) var calls: [JSONValue] = []
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "chat.history" else { return .object([:]) }
        calls.append(params)
        let first = calls.count == 1
        let page = params["offset"] != .null
        let message = first ? "old-transcript" : page ? "wrong-offset-page" : "new-transcript"
        return .object([
            "sessionId": .string(first ? "physical-old" : "physical-new"),
            "messages": .array([.object(["id": .string(message), "role": .string("assistant"), "content": .string(message)])]),
            "hasMore": .bool(first || page), "nextOffset": .number(page ? 200 : 100),
        ])
    }
}

@Test @MainActor func olderPageFromAReplacementTranscriptRefreshesInsteadOfMixingRows() async throws {
    let service = ReplacedHistoryPages()
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical-old", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    let app = AppModel(service: service, initialStore: store)
    try await app.refreshHistory(for: main)
    await app.loadOlderHistory()
    #expect(app.selectedSession?.sessionID == "physical-new")
    #expect(app.messages.map(\.text) == ["new-transcript"])
    #expect(await service.calls.count == 3)
    #expect(await service.calls.last?["offset"] == .null)
    #expect(!app.hasMoreHistory)
}
