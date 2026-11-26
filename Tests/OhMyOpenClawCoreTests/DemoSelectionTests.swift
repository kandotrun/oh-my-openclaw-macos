import Testing
@testable import OhMyOpenClawCore

@Test func demoSideCreationPreservesModelAndThinkingSelection() async throws {
    let gateway = DemoGateway()
    _ = try await gateway.connect()
    let created = try await gateway.request(method: "sessions.create", params: .object(["model": .string("demo/balanced"), "thinkingLevel": .string("high"), "titleSource": .string("Planning")]))
    #expect(created["entry"]["model"].stringValue == "demo/balanced")
    #expect(created["entry"]["thinkingLevel"].stringValue == "high")
    await gateway.disconnect()
}
