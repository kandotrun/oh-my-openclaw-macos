import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor IdleGateway: GatewayServing {
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func request(method: String, params: JSONValue) async throws -> JSONValue { .object([:]) }
}

/// The importer's MIME type decides which Gateway ceiling applies at registration.
@Test @MainActor func attachmentRegistrationAppliesTheFileOrImageLimitByMIMEType() {
    let thread = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "p", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(thread); store.selectedID = thread.id
    let policy: JSONValue = .object(["attachments": .object(["maxImageBytes": .number(10), "maxBytes": .number(1_000)])])
    let app = AppModel(service: IdleGateway(), initialStore: store, policy: policy)
    app.addAttachment(data: Data(count: 100), fileName: "logo.svg", mimeType: "application/octet-stream")
    #expect(app.attachments.map(\.fileName) == ["logo.svg"])
    app.addAttachment(data: Data(count: 100), fileName: "photo.png", mimeType: "image/png")
    #expect(app.attachments.map(\.fileName) == ["logo.svg"])
    #expect(app.errorMessage != nil)
}
