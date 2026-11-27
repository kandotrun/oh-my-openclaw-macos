import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor RecordingDisk: ConversationPersisting {
    private(set) var writes: [ConversationStore] = []
    func load() async throws -> ConversationStore { ConversationStore() }
    func save(_ state: ConversationStore, revision: Int) async throws { writes.append(state) }
}

/// A Gateway whose hello may name the viewer, and whose `users.self` answers with `selfResult`.
private actor ViewerGateway: GatewayServing {
    private let presenceProfile: String?
    private let selfResult: Result<JSONValue, GatewayFailure>?
    private(set) var selfRequests = 0
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    init(presenceProfile: String? = nil, selfResult: Result<JSONValue, GatewayFailure>? = nil) {
        self.presenceProfile = presenceProfile; self.selfResult = selfResult
    }
    func connect() async throws -> GatewayHello {
        var user: [String: JSONValue] = ["id": .string("someone")]
        if let presenceProfile { user = ["id": .string(presenceProfile), "identity": .object(["type": .string("profile"), "id": .string(presenceProfile)])] }
        return GatewayHello(payload: .object([
            "server": .object(["connId": .string("c1")]),
            "features": .object(["methods": .array(selfResult == nil ? [] : [.string("users.self")])]),
            "snapshot": .object([
                "sessionDefaults": .object(["defaultAgentId": .string("a"), "mainSessionKey": .string("agent:a:main")]),
                "presence": .array([.object(["connectionId": .string("c1"), "ts": .number(0), "user": .object(user)])]),
            ]),
        ]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let channel = AsyncStream<GatewayEvent>.makeStream()
        continuation = channel.continuation
        return channel.stream
    }
    func disconnect() async { continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "chat.history": return .object(["sessionId": .string("physical"), "messages": .array([])])
        case "users.self":
            selfRequests += 1
            return try selfResult!.get()
        default: return .object([:])
        }
    }
}

private func cached(_ id: String?) -> ConversationStore {
    var store = ConversationStore()
    store.viewerProfileID = id
    return store
}

@Test @MainActor func helloPresenceNamesTheViewerAndTheGatewayRemembersIt() async throws {
    let disk = RecordingDisk()
    let app = AppModel(service: ViewerGateway(presenceProfile: "p1"), initialStore: cached(nil), initialPersistence: disk)
    await app.establishConnection()
    await app.viewerTask?.value
    #expect(app.timelineViewer == .profile("p1"))
    #expect(await disk.writes.last?.viewerProfileID == "p1")
    await app.disconnect()
    // While reconnecting, the remembered profile keeps saved rows on their side.
    #expect(app.timelineViewer == .profile("p1"))
}

@Test @MainActor func usersSelfAnswersWhenPresenceDoesNot() async throws {
    let gateway = ViewerGateway(selfResult: .success(.object(["profile": .object(["id": .string("p7")])])))
    let app = AppModel(service: gateway, initialStore: cached(nil))
    await app.establishConnection()
    await app.viewerTask?.value
    #expect(await gateway.selfRequests == 1)
    #expect(app.timelineViewer == .profile("p7"))
    await app.disconnect()
}

@Test @MainActor func forbiddenMeansThisConnectionHasNoProfile() async throws {
    let gateway = ViewerGateway(selfResult: .failure(GatewayFailure(code: "FORBIDDEN", message: "users.self requires an authenticated user")))
    let app = AppModel(service: gateway, initialStore: cached("p1"))
    await app.establishConnection()
    await app.viewerTask?.value
    #expect(app.timelineViewer == .profileless)
    await app.disconnect()
    // The stale profile is forgotten, so it cannot claim rows after a reconnect.
    #expect(app.timelineViewer == .unresolved)
}

@Test @MainActor func otherFailuresKeepTheRememberedViewer() async throws {
    let gateway = ViewerGateway(selfResult: .failure(GatewayFailure(code: "UNAVAILABLE", message: "Synthetic failure")))
    let app = AppModel(service: gateway, initialStore: cached("p1"))
    await app.establishConnection()
    await app.viewerTask?.value
    #expect(await gateway.selfRequests == 1)
    #expect(app.timelineViewer == .profile("p1"))
    await app.disconnect()
}

@Test @MainActor func gatewaysWithoutUsersSelfAreNotAsked() async throws {
    let app = AppModel(service: ViewerGateway(), initialStore: cached(nil))
    await app.establishConnection()
    await app.viewerTask?.value
    #expect(app.timelineViewer == .unresolved)
    await app.disconnect()
}
