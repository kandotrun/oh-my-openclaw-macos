import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor HeldAcknowledgment: GatewayServing {
    private let started = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<JSONValue, any Error>?
    private(set) var sends: [JSONValue] = []
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func waitForSend() async { for await _ in started.stream { return } }
    func finish(reject: Bool = false, uncertain: Bool = false) {
        if uncertain { continuation?.resume(throwing: GatewayFailure(code: "REQUEST_TIMEOUT", message: "Synthetic lost acknowledgment")) }
        else if reject { continuation?.resume(throwing: GatewayFailure(code: "INVALID_REQUEST", message: "Synthetic rejection")) }
        else { continuation?.resume(returning: .object(["runId": sends.last?["idempotencyKey"] ?? .null, "status": .string("started")])) }
        continuation = nil
    }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "chat.send" else { return .object([:]) }
        sends.append(params)
        return try await withCheckedThrowingContinuation { continuation = $0; started.continuation.yield(()) }
    }
}

private actor ReservedInputDisk: ConversationPersisting {
    private(set) var snapshots: [ConversationStore] = []
    private var fails = false
    func load() async throws -> ConversationStore { ConversationStore() }
    func setFailure(_ fails: Bool) { self.fails = fails }
    func save(_ state: ConversationStore, revision: Int) async throws {
        if fails { throw GatewayFailure(code: "DISK_UNAVAILABLE", message: "Synthetic save failure") }
        snapshots.append(state)
    }
}

@Test @MainActor func delayedAcknowledgmentClearsTheComposerBeforeDispatchAndPreservesNewIdenticalInput() async throws {
    let session = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    let attachment = ChatAttachment(fileName: "A.txt", mimeType: "text/plain", data: Data("A".utf8))
    var store = ConversationStore(); store.upsertSession(session); store.selectedID = session.id
    store.setDraft(ComposerDraft(text: "日本語の入力", attachments: [attachment]), for: session.id)
    let gateway = HeldAcknowledgment(); let disk = ReservedInputDisk()
    let app = AppModel(service: gateway, initialStore: store, initialPersistence: disk)
    let sending = Task { await app.send() }
    await gateway.waitForSend()
    #expect(app.draftText.isEmpty && app.attachments.isEmpty)
    #expect(app.messages.filter { $0.role == .user }.count == 1)
    let reserved = try #require(await disk.snapshots.last)
    #expect(reserved.selectedDraft == ComposerDraft())
    #expect(reserved.pending.values.first?.message.attachments == [attachment])
    app.draftText = "日本語の入力"
    app.addAttachment(data: Data("A".utf8), fileName: "A.txt", mimeType: "text/plain")
    await gateway.finish()
    await sending.value
    #expect(app.draftText == "日本語の入力")
    #expect(app.attachments.count == 1)
    #expect(app.messages.filter { $0.role == .user }.count == 1)
    await app.disconnect()
}

@Test @MainActor func rejectedSendKeepsTheFailedInputBesideANewerDraft() async throws {
    let session = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(session); store.selectedID = session.id
    store.setDraft(ComposerDraft(text: "first input"), for: session.id)
    let gateway = HeldAcknowledgment()
    let app = AppModel(service: gateway, initialStore: store)
    let sending = Task { await app.send() }
    await gateway.waitForSend()
    app.draftText = "second input"
    await gateway.finish(reject: true)
    await sending.value
    #expect(app.draftText == "second input")
    #expect(app.messages.first?.text == "first input")
    #expect(app.messages.first?.delivery == .failed)
    let failedID = try #require(app.messages.first?.id)
    let retrying = Task { await app.retryPending(failedID) }
    await gateway.waitForSend()
    await gateway.finish()
    await retrying.value
    let sends = await gateway.sends
    #expect(sends.count == 2)
    #expect(sends.first == sends.last)
    #expect(app.draftText == "second input")
    #expect(app.messages.filter { $0.role == .user }.count == 1)
    await app.disconnect()
}

private actor UnwritableInputDisk: ConversationPersisting {
    func load() async throws -> ConversationStore { ConversationStore() }
    func save(_ state: ConversationStore, revision: Int) async throws {
        throw GatewayFailure(code: "DISK_UNAVAILABLE", message: "Synthetic save failure")
    }
}

@Test @MainActor func aFailedReservationSaveRestoresTheDraftWithoutDispatching() async {
    let session = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(session); store.selectedID = session.id
    store.setDraft(ComposerDraft(text: "not dispatched"), for: session.id)
    let gateway = HeldAcknowledgment()
    let app = AppModel(service: gateway, initialStore: store, initialPersistence: UnwritableInputDisk())
    await app.send()
    #expect(await gateway.sends.isEmpty)
    #expect(app.draftText == "not dispatched")
    #expect(app.messages.isEmpty)
    #expect(app.errorMessage != nil)
    await app.disconnect()
}

@Test @MainActor func aFailedRetrySaveKeepsThePossiblyDispatchedInputsIdentity() async throws {
    let session = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(session); store.selectedID = session.id
    store.setDraft(ComposerDraft(text: "uncertain input"), for: session.id)
    let gateway = HeldAcknowledgment(); let disk = ReservedInputDisk()
    let app = AppModel(service: gateway, initialStore: store, initialPersistence: disk)
    let sending = Task { await app.send() }
    await gateway.waitForSend(); await gateway.finish(uncertain: true); await sending.value
    let inputID = try #require(app.messages.first?.id)
    app.draftText = "uncertain input"
    await disk.setFailure(true)
    await app.retryPending(inputID)
    #expect(app.draftText == "uncertain input")
    #expect(app.messages.first?.id == inputID)
    #expect(app.messages.first?.delivery == .uncertain)
    #expect(await gateway.sends.count == 1)
    await disk.setFailure(false)
    let retrying = Task { await app.retryPending(inputID) }
    await gateway.waitForSend(); await gateway.finish(); await retrying.value
    let sends = await gateway.sends
    #expect(sends.count == 2)
    #expect(sends.first == sends.last)
    #expect(app.messages.filter { $0.role == .user }.count == 1)
    #expect(app.draftText == "uncertain input")
    await app.disconnect()
}

@Test @MainActor func retryingAnOutboxBubblePreservesAnIdenticalNewDraft() async throws {
    for rejected in [false, true] {
        let session = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
        var store = ConversationStore(); store.upsertSession(session); store.selectedID = session.id
        store.setDraft(ComposerDraft(text: "same input"), for: session.id)
        let gateway = HeldAcknowledgment()
        let app = AppModel(service: gateway, initialStore: store)
        let sending = Task { await app.send() }
        await gateway.waitForSend()
        app.draftText = "same input"
        await gateway.finish(reject: rejected, uncertain: !rejected)
        await sending.value
        let inputID = try #require(app.messages.first?.id)
        let retrying = Task { await app.retryPending(inputID) }
        await gateway.waitForSend()
        #expect(app.draftText == "same input")
        await gateway.finish(); await retrying.value
        #expect(app.draftText == "same input")
        let sends = await gateway.sends
        #expect(sends.count == 2)
        #expect(sends.first == sends.last)
        await app.disconnect()
    }
}
