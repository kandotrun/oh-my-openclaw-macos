import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

/// Lists one free-text question in the main thread. The first resolve fails.
private actor OneQuestionGateway: GatewayServing {
    private var resolveAttempts = 0
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?
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
        switch method {
        case "chat.history": return .object(["sessionId": .string("physical"), "messages": .array([])])
        case "question.list":
            return .object(["questions": .array([.object([
                "id": .string("request-1"), "status": .string("pending"),
                "sessionKey": .string("agent:a:main"), "agentId": .string("a"),
                "questions": .array([.object(["questionId": .string("q"), "question": .string("Which branch?")])]),
            ])])])
        case "question.resolve":
            resolveAttempts += 1
            if resolveAttempts == 1 { throw GatewayFailure(code: "UNAVAILABLE", message: "Synthetic failure") }
            return .object(["ok": .bool(true)])
        default: return .object([:])
        }
    }
}

@Test @MainActor func typedAnswerLastsUntilItsQuestionIsResolved() async throws {
    let app = AppModel(service: OneQuestionGateway(), initialStore: ConversationStore())
    await app.establishConnection()
    let prompt = try #require(app.prompts.first)
    app.promptAnswers[prompt.id] = "Start from main"
    await app.resolvePrompt(prompt, answer: "Start from main")
    #expect(app.promptAnswers[prompt.id] == "Start from main")
    await app.resolvePrompt(prompt, answer: "Start from main")
    #expect(app.prompts.isEmpty)
    #expect(app.promptAnswers[prompt.id] == nil)
    await app.disconnect()
}
