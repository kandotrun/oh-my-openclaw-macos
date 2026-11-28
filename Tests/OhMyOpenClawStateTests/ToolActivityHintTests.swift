import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

/// A Gateway that lets the test push events into the live stream.
private actor PushGateway: GatewayServing {
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
        method == "chat.history" ? .object(["sessionId": .string("physical"), "messages": .array([])]) : .object([:])
    }
    func push(_ name: String, _ payload: [String: JSONValue]) {
        var fields: [String: JSONValue] = ["sessionKey": .string("agent:a:main"), "agentId": .string("a"), "runId": .string("run-1")]
        fields.merge(payload) { _, new in new }
        continuation?.yield(GatewayEvent(name: name, payload: .object(fields)))
    }
    func tool(_ phase: String, name: String) {
        push("agent", ["stream": .string("tool"), "data": .object(["phase": .string(phase), "name": .string(name), "toolCallId": .string("call-1")])])
    }
}

@MainActor private func settle(_ app: AppModel, until expected: ActivityState) async -> Bool {
    for _ in 0..<200 where app.activity != expected { try? await Task.sleep(for: .milliseconds(5)) }
    return app.activity == expected
}

/// OpenClaw ends a tool only with `result`; there is no tool `end` or `error` phase.
@Test @MainActor func onlyAToolResultEndsTheSearchingHint() async throws {
    let gateway = PushGateway()
    let app = AppModel(service: gateway, initialStore: ConversationStore())
    await app.establishConnection()
    await gateway.push("chat", ["state": .string("status")])
    #expect(await settle(app, until: .working))
    await gateway.tool("start", name: "web_search")
    #expect(await settle(app, until: .searching))
    await gateway.tool("end", name: "web_search")
    await gateway.tool("update", name: "web_search")
    #expect(!(await settle(app, until: .working)))
    await gateway.tool("result", name: "web_search")
    #expect(await settle(app, until: .working))
    await app.disconnect()
}
