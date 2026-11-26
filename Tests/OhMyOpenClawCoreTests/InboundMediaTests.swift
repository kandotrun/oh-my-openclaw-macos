import Foundation
import Testing
@testable import OhMyOpenClawCore

private let inboundSession = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Photos")
private let inboundReference = InboundMediaReference(source: "media://inbound/photo.png", messageID: "durable-message")!

@Suite("Inbound image previews")
struct InboundMediaTests {
    @Test func metadataOnlyImagesAndOmittedBlocksProduceOnePreviewEach() throws {
        let facts: [JSONValue] = ["one.png", "two.png"].map { name in
            .object(["url": .string("media://inbound/" + name), "contentType": .string("image/png"), "fileName": .string(name), "sizeBytes": .number(3)])
        }
        for content in [JSONValue.string("caption"), .array([
            .object(["type": .string("text"), "text": .string("caption")]),
            .object(["type": .string("image"), "omitted": .bool(true), "bytes": .number(3)]),
            .object(["type": .string("image"), "omitted": .bool(true), "bytes": .number(3)]),
        ])] {
            let row = ConversationStore.parseMessage(.object([
                "role": .string("user"), "content": content,
                "__openclaw": .object(["id": .string("durable-message"), "media": .array(facts)]),
            ]), fallbackID: "fallback")
            #expect(row.attachments.count == 2)
            #expect(row.attachments.map(\.fileName) == ["one.png", "two.png"])
            #expect(row.attachments.map(\.inboundMedia?.messageID) == ["durable-message", "durable-message"])
            #expect(row.attachments.first?.inboundMedia?.source == "media://inbound/one.png")
            #expect(row.attachments.allSatisfy { $0.data.isEmpty })
            #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(row)) == row)
        }
        let legacy = Data(#"{"id":"old","fileName":"old.png","mimeType":"image/png","data":""}"#.utf8)
        #expect(try JSONDecoder().decode(ChatAttachment.self, from: legacy).inboundMedia == nil)
    }

    @Test func mediaFactsNeedCanonicalSourcesAndVisibleAuthoredMessages() {
        for source in ["https://outside.example/image.png", "/home/user/photo.png", "media://other/photo.png",
                       "media://user@inbound/photo.png", "media://inbound/photo.png?token=secret",
                       "media://inbound/photo.png#fragment", "media://inbound/", "media://inbound/..",
                       "media://inbound/%2e%2e", "media://inbound/nested%2fphoto.png", "media://inbound/%00.png",
                       "media://inbound/photo%.png"] {
            #expect(InboundMediaReference(source: source, messageID: "durable") == nil)
        }
        let fact: JSONValue = .object(["path": .string("media://inbound/photo.png"), "contentType": .string("image/png")])
        for changes: [String: JSONValue] in [
            ["display": .bool(false)], ["customType": .string("openclaw.runtime-context")],
            ["role": .string("toolResult")], ["provenance": .object(["kind": .string("internal_system")])],
        ] {
            var value: [String: JSONValue] = ["role": .string("user"), "content": .string("caption"),
                                             "__openclaw": .object(["id": .string("durable"), "media": .array([fact])])]
            value.merge(changes) { _, fresh in fresh }
            #expect(ConversationStore.parseMessage(.object(value), fallbackID: "fallback").attachments.isEmpty)
        }
        #expect(ConversationStore.parseMessage(.object([
            "role": .string("user"), "__openclaw": .object(["media": .array([fact])]),
        ]), fallbackID: "history:0").attachments.isEmpty)
    }

    @Test func requestsStayOnTheConfiguredOriginAndSeparateCredentials() throws {
        for endpoint in ["wss://gateway.example/claw", "wss://gateway.example/claw/"] {
            let base = try #require(URL(string: endpoint))
            let metadata = try GatewayInboundMediaLoader.metadataRequest(inboundReference, session: inboundSession, endpoint: base, deviceToken: "paired-device-token")
            let bytes = try GatewayInboundMediaLoader.bytesRequest(inboundReference, session: inboundSession, endpoint: base, mediaTicket: "short-lived-ticket")
            #expect(metadata.url?.scheme == "https")
            #expect(metadata.url?.host == "gateway.example")
            #expect(metadata.url?.path == "/claw/__openclaw__/assistant-media")
            #expect(metadata.value(forHTTPHeaderField: "Authorization") == "Bearer paired-device-token")
            #expect(bytes.value(forHTTPHeaderField: "Authorization") == nil)
            let metaQuery = URLComponents(url: metadata.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let bytesQuery = URLComponents(url: bytes.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(metaQuery.first { $0.name == "source" }?.value == inboundReference.source)
            #expect(metaQuery.first { $0.name == "messageId" }?.value == inboundReference.messageID)
            #expect(metaQuery.first { $0.name == "meta" }?.value == "1")
            #expect(!metadata.url!.absoluteString.contains("paired-device-token"))
            #expect(bytesQuery.first { $0.name == "mediaTicket" }?.value == "short-lived-ticket")
            #expect(bytesQuery.first { $0.name == "meta" } == nil)
            #expect(bytesQuery.first { $0.name == "width" }?.value == "960")
        }
        for endpoint in ["ws://outside.example", "wss://user:password@gateway.example", "wss://gateway.example/?token=bad",
                         "wss://gateway.example/#fragment", "wss://gateway.example/claw/%2e%2e", "wss://gateway.example/claw/%2fother"] {
            #expect(throws: GatewayFailure.self) {
                try GatewayInboundMediaLoader.metadataRequest(inboundReference, session: inboundSession, endpoint: URL(string: endpoint)!, deviceToken: "device")
            }
        }
        #expect(try GatewayInboundMediaLoader.metadataRequest(inboundReference, session: inboundSession, endpoint: URL(string: "ws://127.0.0.1:18789")!, deviceToken: "device").url?.scheme == "http")
        let forged = try JSONDecoder().decode(InboundMediaReference.self, from: Data(#"{"source":"https://outside.example/image.png","messageID":"durable"}"#.utf8))
        #expect(throws: GatewayFailure.self) {
            try GatewayInboundMediaLoader.metadataRequest(forged, session: inboundSession, endpoint: URL(string: "wss://gateway.example")!, deviceToken: "device")
        }
    }

    @Test func metadataGrantThenTicketOnlyBytesAreReadWithBounds() async throws {
        let fetch = InboundFetch()
        let data = try await GatewayInboundMediaLoader.load(inboundReference, session: inboundSession, endpoint: URL(string: "wss://gateway.example")!, deviceToken: "paired-device-token") {
            try await fetch.fetch($0, limit: $1)
        }
        #expect(data == Data([1, 2, 3]))
        let requests = await fetch.requests
        #expect(requests.count == 2)
        #expect(requests[0].0.value(forHTTPHeaderField: "Authorization") == "Bearer paired-device-token")
        #expect(requests[0].1 == GatewayInboundMediaLoader.metadataLimit)
        #expect(requests[1].0.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].1 == GatewayInboundMediaLoader.imageLimit)
    }

    @Test func unavailableExpiredOversizedAndNonImageResponsesAreRejected() async {
        for failure in InboundFetch.Failure.allCases {
            let fetch = InboundFetch(failure: failure)
            await #expect(throws: GatewayFailure.self) {
                try await GatewayInboundMediaLoader.load(inboundReference, session: inboundSession, endpoint: URL(string: "wss://gateway.example")!, deviceToken: "device") {
                    try await fetch.fetch($0, limit: $1)
                }
            }
            if failure != .bytesMIME && failure != .bytesTooLarge {
                #expect(await fetch.requests.count == 1)
            }
        }
    }

    @Test func redirectsAreRefusedAndDisconnectedClientsCannotRead() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://gateway.example/__openclaw__/assistant-media")!
        let task = session.dataTask(with: original)
        let redirect = URLRequest(url: URL(string: "https://outside.example/")!)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirect.url!.absoluteString])!
        let decision: URLRequest? = await withCheckedContinuation { continuation in
            InboundMediaRedirectRefusal().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) {
                continuation.resume(returning: $0)
            }
        }
        #expect(decision == nil)
        let client = GatewayClient(endpoint: URL(string: "wss://gateway.example")!, credentials: GatewayCredentials(password: "synthetic-password"), identity: DeviceIdentity())
        await #expect(throws: GatewayFailure.self) { try await client.loadInboundMedia(inboundReference, session: inboundSession) }
    }
}

private actor InboundFetch {
    enum Failure: CaseIterable { case unavailable, expired, metadataTooLarge, advertisedTooLarge, bytesMIME, bytesTooLarge }
    let failure: Failure?
    var requests: [(URLRequest, Int)] = []
    init(failure: Failure? = nil) { self.failure = failure }

    func fetch(_ request: URLRequest, limit: Int) throws -> (Data, HTTPURLResponse) {
        requests.append((request, limit))
        let metadata = requests.count == 1
        var data: Data
        let mime: String
        if metadata {
            var value: [String: JSONValue] = [
                "available": .bool(failure != .unavailable), "mimeType": .string("image/png"),
                "sizeBytes": .number(failure == .advertisedTooLarge ? Double(GatewayInboundMediaLoader.imageLimit + 1) : 3),
                "mediaTicket": .string("synthetic-ticket"),
                "mediaTicketExpiresAt": .string(failure == .expired ? "2000-01-01T00:00:00.000Z" : "2099-01-01T00:00:00.000Z"),
            ]
            if failure == .metadataTooLarge { value["padding"] = .string(String(repeating: "x", count: GatewayInboundMediaLoader.metadataLimit)) }
            data = try JSONEncoder().encode(JSONValue.object(value)); mime = "application/json"
        } else {
            data = failure == .bytesTooLarge ? Data(repeating: 0, count: GatewayInboundMediaLoader.imageLimit + 1) : Data([1, 2, 3])
            mime = failure == .bytesMIME ? "text/html" : "image/png"
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!)
    }
}
