import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor HistoryBeforeSend: GatewayServing {
    let holdFirstRead: Bool
    let failFirstSend: Bool
    private let started = AsyncStream<Void>.makeStream()
    private var held: CheckedContinuation<Void, Never>?
    private var reads = 0
    private(set) var sends: [JSONValue] = []
    private(set) var aborts: [JSONValue] = []
    init(holdFirstRead: Bool = true, failFirstSend: Bool = false) { self.holdFirstRead = holdFirstRead; self.failFirstSend = failFirstSend }
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func waitForRead() async { for await _ in started.stream { return } }
    func releaseRead() { held?.resume(); held = nil }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        if method == "chat.history" {
            reads += 1
            if reads == 1 && holdFirstRead { await withCheckedContinuation { held = $0; started.continuation.yield(()) } }
            return .object(["sessionId": .string("physical"), "messages": .array([])])
        }
        if method == "chat.send" {
            sends.append(params)
            if failFirstSend && sends.count == 1 { throw GatewayFailure(code: "REQUEST_TIMEOUT", message: "Synthetic lost acknowledgment") }
            return .object(["status": .string("started"), "runId": params["idempotencyKey"]])
        }
        if method == "chat.abort" { aborts.append(params) }
        return .object([:])
    }
}

private actor HeldSendPersistence: ConversationPersisting {
    private let started = AsyncStream<Void>.makeStream()
    private var hold: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(hold: Bool = true) { self.hold = hold }
    func load() async throws -> ConversationStore { ConversationStore() }
    func save(_ state: ConversationStore, revision: Int) async throws {
        if hold { await withCheckedContinuation { waiters.append($0); started.continuation.yield(()) } }
    }
    func waitForSave() async { for await _ in started.stream { return } }
    func pauseSaves() { hold = true }
    func releaseSaves() { hold = false; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

@Test @MainActor func stopBeforeTheFirstSaveCompletesCancelsTheLocalSend() async throws {
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "unsent draft"), for: main.id)
    let service = HistoryBeforeSend(holdFirstRead: false)
    let disk = HeldSendPersistence()
    let app = AppModel(service: service, initialStore: store, initialPersistence: disk)
    let sending = Task { await app.send() }
    await disk.waitForSave()
    let stopping = Task { await app.stop() }
    let deadline = ContinuousClock.now + .seconds(1)
    while app.activity != .idle && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    await disk.releaseSaves()
    await stopping.value; await sending.value
    #expect(await service.sends.isEmpty)
    #expect(await service.aborts.isEmpty)
    #expect(app.activity == .idle)
    #expect(app.draftText == "unsent draft")
    #expect(app.messages.isEmpty)
    await app.disconnect()
}

@Test @MainActor func stoppingAPreparedRetryStillAbortsThePreviouslyDispatchedRun() async throws {
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "uncertain draft"), for: main.id)
    let service = HistoryBeforeSend(holdFirstRead: false, failFirstSend: true)
    let disk = HeldSendPersistence(hold: false)
    let app = AppModel(service: service, initialStore: store, initialPersistence: disk)
    await app.send()
    let runID = try #require(await service.sends.first?["idempotencyKey"].stringValue)
    await disk.pauseSaves()
    let retrying = Task { await app.retryPending(runID) }
    await disk.waitForSave()
    await app.stop()
    await disk.releaseSaves()
    await retrying.value
    #expect(await service.sends.count == 1)
    #expect(await service.aborts.first?["runId"].stringValue == runID)
    await app.disconnect()
}

@Test @MainActor func historyDuringThePreparedSendSaveCannotRetireItsReservedRun() async throws {
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "reserved input"), for: main.id)
    let service = HistoryBeforeSend(holdFirstRead: false)
    let disk = HeldSendPersistence()
    let app = AppModel(service: service, initialStore: store, initialPersistence: disk)
    let sending = Task { await app.send() }
    await disk.waitForSave()
    try await app.refreshHistory(for: main)
    #expect(app.activity == .working)
    await disk.releaseSaves()
    await sending.value
    let expectedRun = try #require(await service.sends.first?["idempotencyKey"].stringValue)
    app.draftText = "next input"
    #expect(app.activity == .working)
    #expect(!app.canSend)
    await app.stop()
    #expect(await service.aborts.first?["runId"].stringValue == expectedRun)
    await app.disconnect()
}

@Test @MainActor func historyReadStartedBeforeLocalSendCannotRetireTheNewRun() async throws {
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "send after history starts"), for: main.id)
    let service = HistoryBeforeSend()
    let app = AppModel(service: service, initialStore: store)
    let history = Task { try await app.refreshHistory(for: main) }
    await service.waitForRead()
    await app.send()
    let expectedRun = try #require(await service.sends.first?["idempotencyKey"].stringValue)
    await service.releaseRead()
    try await history.value
    #expect(app.activity == .working)
    await app.stop()
    #expect(await service.aborts.first?["runId"].stringValue == expectedRun)
}
