import Foundation
import Testing
@testable import OhMyOpenClawCore

@Suite("Gateway attachment references")
struct ArtifactReferenceTests {
    @Test func managedImageRetainsURLAndDerivesScopedArtifactID() throws {
        let path = "/api/chat/media/outgoing/agent%3Amain%3Amain/11111111-1111-4111-8111-111111111111/full"
        let block: JSONValue = .object(["type": .string("image"), "url": .string(path), "openUrl": .string(path), "mimeType": .string("image/png"), "alt": .string("Generated image")])
        let attachment = try #require(ChatAttachment.parse(block: block, fallbackID: "row:0"))
        #expect(attachment.artifactID == "artifact_managed_image_11111111-1111-4111-8111-111111111111")
        #expect(attachment.url == path)
        #expect(attachment.openURL == path)
        #expect(attachment.data.isEmpty)
        let reloaded = try JSONDecoder().decode(ChatAttachment.self, from: JSONEncoder().encode(attachment))
        #expect(reloaded == attachment)
    }

    @Test func nestedManagedDocumentDoesNotDisappear() throws {
        let block: JSONValue = .object(["type": .string("attachment"), "attachment": .object([
            "artifactId": .string("artifact_managed_media_11111111-1111-4111-8111-111111111111"),
            "kind": .string("document"), "label": .string("report.csv"), "mimeType": .string("text/csv"), "sizeBytes": .number(12),
            "url": .string("/api/chat/media/outgoing/agent%3Amain%3Amain/11111111-1111-4111-8111-111111111111/full"),
        ])])
        let attachment = try #require(ChatAttachment.parse(block: block, fallbackID: "row:1"))
        #expect(attachment.fileName == "report.csv")
        #expect(attachment.mimeType == "text/csv")
        #expect(attachment.sizeBytes == 12)
        #expect(attachment.artifactID == "artifact_managed_media_11111111-1111-4111-8111-111111111111")
        #expect(attachment.url?.hasPrefix("/api/chat/media/outgoing/") == true)
    }

    @Test func inlineImageBytesAndUnknownBlocksRemainDistinct() throws {
        let bytes = Data([1, 2, 3])
        let block: JSONValue = .object(["type": .string("image"), "source": .object(["media_type": .string("image/png"), "data": .string(bytes.base64EncodedString())])])
        let attachment = try #require(ChatAttachment.parse(block: block, fallbackID: "inline"))
        #expect(attachment.data == bytes)
        #expect(attachment.artifactID == nil)
        #expect(ChatAttachment.parse(block: .object(["type": .string("text"), "text": .string("ordinary text")]), fallbackID: "text") == nil)
    }

    @Test func downloadUsesAuthenticatedRPCAndExactArtifactTarget() async throws {
        let service = ArtifactService(response: .object(["artifact": .object(["id": .string("file-id")]), "encoding": .string("base64"), "data": .string(Data("report".utf8).base64EncodedString())]))
        let target = ChatSession(key: "agent:a:dashboard:one", agentID: "a", sessionID: "physical-one", title: "One")
        let attachment = ChatAttachment(fileName: "report.csv", mimeType: "text/csv", data: Data(), artifactID: "file-id")
        let data = try await GatewayArtifactLoader.load(attachment, session: target, service: service, endpoint: URL(string: "wss://gateway.example")!)
        #expect(String(decoding: data, as: UTF8.self) == "report")
        let calls = await service.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == "artifacts.download")
        #expect(calls.first?.1 == .object(["sessionKey": .string(target.key), "agentId": .string("a"), "artifactId": .string("file-id")]))
    }

    @Test func downloadRejectsChangedIdentityAndExternalURLs() async {
        let target = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main")
        let attachment = ChatAttachment(fileName: "image.png", mimeType: "image/png", data: Data(), artifactID: "expected")
        let service = ArtifactService(response: .object(["artifact": .object(["id": .string("other")]), "encoding": .string("base64"), "data": .string("eA==")]))
        await #expect(throws: GatewayFailure.self) { try await GatewayArtifactLoader.load(attachment, session: target, service: service, endpoint: URL(string: "wss://gateway.example")!) }
        let external = ArtifactService(response: .object(["artifact": .object(["id": .string("expected")]), "url": .string("https://other.example/api/artifacts/download/signed")]))
        await #expect(throws: GatewayFailure.self) { try await GatewayArtifactLoader.load(attachment, session: target, service: external, endpoint: URL(string: "wss://gateway.example")!) }
    }

    @Test func downloadURLsStayWithinConfiguredOriginAndBasePath() throws {
        let root = URL(string: "wss://gateway.example")!
        #expect(try GatewayArtifactLoader.trustedDownloadURL("/api/artifacts/download/signed?ticket=ephemeral", endpoint: root).absoluteString == "https://gateway.example/api/artifacts/download/signed?ticket=ephemeral")
        let nested = URL(string: "wss://gateway.example/claw/")!
        #expect(try GatewayArtifactLoader.trustedDownloadURL("/claw/api/artifacts/download/signed", endpoint: nested).path == "/claw/api/artifacts/download/signed")
        for invalid in ["https://other.example/api/artifacts/download/signed", "//gateway.example/api/artifacts/download/signed", "http://gateway.example/api/artifacts/download/signed", "https://user:password@gateway.example/api/artifacts/download/signed", "/api/artifacts/download/signed#fragment", "/ordinary-file", "/api/artifacts/download/%2e%2e/other", "/api/artifacts/download/%2fother"] {
            #expect(throws: GatewayFailure.self) { try GatewayArtifactLoader.trustedDownloadURL(invalid, endpoint: root) }
        }
        #expect(try GatewayArtifactLoader.trustedDownloadURL("/api/artifacts/download/signed", endpoint: nested).path == "/claw/api/artifacts/download/signed")
    }

    @Test func rootRelativeArtifactTicketsUseTheDeploymentPrefix() throws {
        let managed = "/api/chat/media/outgoing/agent%3Aa%3Amain/11111111-1111-4111-8111-111111111111/full?mediaTicket=synthetic-ticket"
        let inline = "/api/artifacts/download/synthetic-ticket?variant=thumbnail"
        for endpoint in ["wss://gateway.example/claw", "wss://gateway.example/claw/"] {
            let url = URL(string: endpoint)!
            #expect(try GatewayArtifactLoader.trustedDownloadURL(managed, endpoint: url).absoluteString == "https://gateway.example/claw" + managed)
            #expect(try GatewayArtifactLoader.trustedDownloadURL(inline, endpoint: url).absoluteString == "https://gateway.example/claw" + inline)
            #expect(throws: GatewayFailure.self) { try GatewayArtifactLoader.trustedDownloadURL("/other/api/artifacts/download/ticket", endpoint: url) }
        }
    }
}

private actor ArtifactService: GatewayServing {
    let response: JSONValue
    var calls: [(String, JSONValue)] = []
    init(response: JSONValue) { self.response = response }
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func request(method: String, params: JSONValue) async throws -> JSONValue { calls.append((method, params)); return response }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
