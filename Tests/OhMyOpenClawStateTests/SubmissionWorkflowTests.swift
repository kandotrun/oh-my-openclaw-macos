import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor SubmissionGateway: GatewayServing {
    let holdCreation: Bool
    let failFirstSend: Bool
    private let started = AsyncStream<Void>.makeStream()
    private var creation: CheckedContinuation<JSONValue, any Error>?
    private(set) var creates: [JSONValue] = []
    private(set) var sends: [JSONValue] = []
    private(set) var aborts: [JSONValue] = []

    init(holdCreation: Bool = false, failFirstSend: Bool = false) { self.holdCreation = holdCreation; self.failFirstSend = failFirstSend }
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func waitForCreation() async { for await _ in started.stream { return } }
    func releaseCreation() {
        creation?.resume(returning: creationResponse(creates.last ?? .null)); creation = nil
    }
    private func creationResponse(_ params: JSONValue) -> JSONValue {
        let key = params["key"].stringValue ?? "agent:a:dashboard:created"
        return .object(["key": .string(key), "sessionId": .string("new-physical"), "entry": .object(["key": .string(key), "sessionId": .string("new-physical"), "agentId": .string("a")])])
    }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        if method == "sessions.create" {
            creates.append(params)
            if holdCreation {
                return try await withCheckedThrowingContinuation { continuation in
                    creation = continuation; started.continuation.yield(())
                }
            }
            return creationResponse(params)
        }
        if method == "chat.send" {
            sends.append(params)
            if failFirstSend && sends.count == 1 { throw GatewayFailure(code: "REQUEST_TIMEOUT", message: "Synthetic lost acknowledgment") }
            return .object(["runId": params["idempotencyKey"], "status": .string("started")])
        }
        if method == "chat.abort" { aborts.append(params) }
        return .object([:])
    }
}

@MainActor private func model(session: ChatSession, draft: ComposerDraft, service: SubmissionGateway) -> AppModel {
    var store = ConversationStore()
    store.upsertSession(session); store.selectedID = session.id; store.setDraft(draft, for: session.id)
    return AppModel(service: service, initialStore: store)
}

@Test @MainActor func firstMainMessageMaterializesItsExistingLogicalKey() async throws {
    let service = SubmissionGateway()
    let main = ChatSession(key: "agent:a:main", agentID: "a", title: "Main", isMain: true)
    let app = model(session: main, draft: ComposerDraft(text: "first message"), service: service)
    await app.send()
    let creation = try #require(await service.creates.first)
    let sent = try #require(await service.sends.first)
    #expect(creation["key"].stringValue == main.key)
    #expect(sent["sessionKey"].stringValue == main.key)
    #expect(sent["sessionId"].stringValue == "new-physical")
    #expect(sent["message"].stringValue == "first message")
    #expect(app.selectedSession?.isMain == true)
}

@Test @MainActor func delayedCreationKeepsTappedInputSeparateFromLaterEdits() async throws {
    let service = SubmissionGateway(holdCreation: true)
    let side = ChatSession(key: "local:draft", agentID: "a", title: "New side")
    let first = ChatAttachment(fileName: "A.txt", mimeType: "text/plain", data: Data("original".utf8))
    let app = model(session: side, draft: ComposerDraft(text: "A 日本語", attachments: [first]), service: service)
    let sending = Task { await app.send() }
    await service.waitForCreation()
    app.draftText = "B 新しい下書き"
    app.removeAttachment(first.id)
    app.addAttachment(data: Data("new".utf8), fileName: "B.txt", mimeType: "text/plain")
    await service.releaseCreation()
    await sending.value
    let sent = try #require(await service.sends.first)
    #expect(sent["message"].stringValue == "A 日本語")
    #expect(sent["attachments"].arrayValue?.first?["fileName"].stringValue == "A.txt")
    #expect(app.draftText == "B 新しい下書き")
    #expect(app.attachments.map(\.fileName) == ["B.txt"])
    #expect(app.messages.first?.text == "A 日本語")
}

@Test @MainActor func stopDuringLazyCreationPreventsThePreparedMessageFromSending() async {
    let service = SubmissionGateway(holdCreation: true)
    let side = ChatSession(key: "local:stopped", agentID: "a", title: "New side")
    let app = model(session: side, draft: ComposerDraft(text: "keep this draft"), service: service)
    let sending = Task { await app.send() }
    await service.waitForCreation()
    await app.stop()
    await service.releaseCreation()
    await sending.value
    #expect(await service.sends.isEmpty)
    #expect(await service.aborts.isEmpty)
    #expect(app.activity == .idle)
    #expect(app.draftText == "keep this draft")
    #expect(app.messages.isEmpty)
    #expect(app.canSend)
}

@Test @MainActor func ordinarySendRetriesUncertainInputWithItsOriginalIdentity() async throws {
    let service = SubmissionGateway(failFirstSend: true)
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    let app = model(session: main, draft: ComposerDraft(text: "exactly once"), service: service)
    await app.send()
    #expect(app.draftText.isEmpty)
    #expect(!app.canSend)
    #expect(app.messages.first?.delivery == .uncertain)
    app.draftText = "exactly once"
    #expect(app.canSend)
    await app.send()
    let sent = await service.sends
    #expect(sent.count == 2)
    #expect(sent[0] == sent[1])
    #expect(app.messages.filter { $0.role == .user }.count == 1)
    #expect(app.draftText.isEmpty)
}

@Test @MainActor func ordinarySendUsesTheReplacementPhysicalSessionForAnUnchangedDraft() async throws {
    let service = SubmissionGateway()
    let original = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore()
    store.upsertSession(original); store.selectedID = original.id
    store.setDraft(ComposerDraft(text: "unchanged draft"), for: original.id)
    let old = try store.prepareSubmission(for: original, policy: .null)
    store.markUncertain(old.id)
    var replacement = original; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    store.setDraft(ComposerDraft(text: "unchanged draft"), for: replacement.id)
    let app = AppModel(service: service, initialStore: store)
    await app.send()
    let sent = try #require(await service.sends.first)
    #expect(sent["sessionId"].stringValue == "replacement")
    #expect(sent["idempotencyKey"].stringValue != old.id)
    #expect(sent["message"].stringValue == "unchanged draft")
    #expect(app.errorMessage == nil)
    #expect(app.messages.filter { $0.role == .user }.count == 1)
}

@Test @MainActor func distinctNewInputCanFollowAnUncertainSubmission() async throws {
    let service = SubmissionGateway(failFirstSend: true)
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    let app = model(session: main, draft: ComposerDraft(text: "original"), service: service)
    await app.send()
    app.draftText = "distinct next message"
    await app.send()
    let sent = await service.sends
    #expect(sent.count == 2)
    #expect(sent[0]["idempotencyKey"] != sent[1]["idempotencyKey"])
    #expect(sent[1]["message"].stringValue == "distinct next message")
    #expect(app.messages.filter { $0.role == .user }.count == 2)
}

@Test @MainActor func explicitResumeRestoresAutomaticReconnectIntent() async {
    let service = SubmissionGateway()
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    let app = model(session: main, draft: ComposerDraft(), service: service)
    await app.disconnect()
    #expect(!app.autoConnect)
    await app.retryConnection()
    #expect(app.autoConnect)
}

@Test @MainActor func retryOfOlderUncertainInputCannotReplaceTheRunningResponse() async throws {
    let service = SubmissionGateway()
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore()
    store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "A"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    store.markUncertain(old.id)
    store.setDraft(ComposerDraft(text: "B"), for: main.id)
    let running = try store.prepareSubmission(for: main, policy: .null)
    store.acknowledge(running.id)
    let app = AppModel(service: service, initialStore: store)
    await app.retryPending(old.id)
    #expect(await service.sends.isEmpty)
    #expect(app.activity != .idle)
    await app.stop()
    #expect(await service.aborts.first?["runId"].stringValue == running.id)
}

@Test @MainActor func sendQueuedInOneThreadNeverSendsAThreadChosenLater() async throws {
    let service = SubmissionGateway()
    let first = ChatSession(key: "agent:a:dashboard:first", agentID: "a", sessionID: "first-physical", title: "First")
    let second = ChatSession(key: "agent:a:dashboard:second", agentID: "a", sessionID: "second-physical", title: "Second")
    var store = ConversationStore()
    store.upsertSession(first); store.upsertSession(second); store.selectedID = first.id
    store.setDraft(ComposerDraft(text: "first draft"), for: first.id)
    store.setDraft(ComposerDraft(text: "second draft"), for: second.id)
    let app = AppModel(service: service, initialStore: store)
    let queued = app.composerContextID
    await app.selectSession(second)
    await app.send(expecting: queued)
    #expect(await service.sends.isEmpty)
    #expect(app.draftText == "second draft")
    await app.send(expecting: app.composerContextID)
    #expect(await service.sends.first?["message"].stringValue == "second draft")
}
