import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor HeldPromptListGateway: GatewayServing {
    let family: String
    let runID: String
    private let listStarted = AsyncStream<Void>.makeStream()
    private var listWaiter: CheckedContinuation<Void, Never>?
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?
    init(family: String, runID: String) { self.family = family; self.runID = runID }
    func connect() async throws -> GatewayHello {
        GatewayHello(payload: .object(["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("a"), "mainSessionKey": .string("agent:a:main"),
        ])])]))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let channel = AsyncStream<GatewayEvent>.makeStream()
        eventContinuation = channel.continuation
        return channel.stream
    }
    func disconnect() async { eventContinuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        if method == "chat.history" {
            return .object(["sessionId": .string("physical"), "messages": .array([]), "inFlightRun": .object(["runId": .string(runID)])])
        }
        if method == family + ".list" {
            await withCheckedContinuation { listWaiter = $0; listStarted.continuation.yield(()) }
            let record: JSONValue = .object([
                "id": .string("request-1"), "status": .string("pending"),
                "sessionKey": .string("agent:a:main"), "agentId": .string("a"),
                "questions": .array([.object(["questionId": .string("q"), "question": .string("Synthetic question")])]),
            ])
            return .object([family == "question" ? "questions" : "approvals": .array([record])])
        }
        return .object([:])
    }
    func waitForList() async { for await _ in listStarted.stream { return } }
    func resolveAndFinish() {
        eventContinuation?.yield(GatewayEvent(name: family + ".resolved", payload: .object(["id": .string("request-1")])))
        eventContinuation?.yield(GatewayEvent(name: "chat", payload: .object([
            "sessionKey": .string("agent:a:main"), "agentId": .string("a"), "runId": .string(runID),
            "state": .string("final"), "message": .object(["role": .string("assistant"), "content": .string("done")]),
        ])))
    }
    func releaseList() { listWaiter?.resume(); listWaiter = nil }
}

@Test(arguments: ["question", "exec.approval", "plugin.approval"])
@MainActor func resolvedPromptCannotReturnFromAnOlderListSnapshot(family: String) async throws {
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var state = ConversationStore(); state.upsertSession(main); state.selectedID = main.id
    state.setDraft(ComposerDraft(text: "original input"), for: main.id)
    let submission = try state.prepareSubmission(for: main, policy: .null)
    state.setDraft(ComposerDraft(text: "next input"), for: main.id)
    let gateway = HeldPromptListGateway(family: family, runID: submission.id)
    let app = AppModel(service: gateway, initialStore: state)
    let connecting = Task { await app.establishConnection() }
    await gateway.waitForList()
    await gateway.resolveAndFinish()
    let deadline = ContinuousClock.now + .seconds(2)
    while app.activity != .idle && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(app.activity == .idle)
    await gateway.releaseList()
    await connecting.value
    #expect(app.prompts.isEmpty)
    #expect(app.activity == .idle)
    #expect(app.canSend)
    #expect(app.draftText == "next input")
    await app.disconnect()
}
