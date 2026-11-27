import Foundation
import Testing
@testable import OhMyOpenClawCore

private let accessSession = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Photos")
private let accessReference = InboundMediaReference(source: "media://inbound/photo.png", messageID: "durable-message")!
private let serviceToken = CloudflareAccessToken(clientID: "client.access", clientSecret: "client-secret")!

private func headers(_ request: URLRequest) -> (id: String?, secret: String?) {
    (request.value(forHTTPHeaderField: "CF-Access-Client-Id"), request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
}

@Suite("Cloudflare Access service tokens")
struct CloudflareAccessTests {
    @Test func serviceTokenNeedsBothPartsAsSafeHeaderValues() {
        #expect(CloudflareAccessToken(clientID: " client.access ", clientSecret: " client-secret\n") == serviceToken)
        #expect(CloudflareAccessToken(clientID: "client.access", clientSecret: "  ") == nil)
        #expect(CloudflareAccessToken(clientID: "", clientSecret: "client-secret") == nil)
        #expect(CloudflareAccessToken(clientID: "client\r\nX-Injected: 1", clientSecret: "client-secret") == nil)
    }

    @Test func socketUpgradeCarriesTheServiceTokenOnlyWhenOneIsSaved() {
        let endpoint = URL(string: "wss://gateway.example.com/openclaw")!
        let plain = GatewayClient.upgradeRequest(endpoint, credentials: GatewayCredentials(token: "gateway-token"))
        #expect(headers(plain).id == nil && headers(plain).secret == nil)
        let protected = GatewayClient.upgradeRequest(endpoint, credentials: GatewayCredentials(token: "gateway-token", access: serviceToken))
        #expect(headers(protected).id == "client.access" && headers(protected).secret == "client-secret")
        #expect(protected.url == endpoint)
    }

    @Test func imageAndAttachmentRequestsToTheGatewayCarryTheServiceToken() throws {
        let endpoint = URL(string: "wss://gateway.example.com")!
        let metadata = try GatewayInboundMediaLoader.metadataRequest(accessReference, session: accessSession, endpoint: endpoint,
                                                                     deviceToken: "device", access: serviceToken)
        let bytes = try GatewayInboundMediaLoader.bytesRequest(accessReference, session: accessSession, endpoint: endpoint,
                                                               mediaTicket: "ticket", access: serviceToken)
        let download = GatewayArtifactLoader.downloadRequest(URL(string: "https://gateway.example.com/download/1")!, access: serviceToken)
        for request in [metadata, bytes, download] {
            #expect(headers(request).id == "client.access" && headers(request).secret == "client-secret")
        }
        #expect(headers(GatewayArtifactLoader.downloadRequest(URL(string: "https://gateway.example.com/download/1")!, access: nil)).id == nil)
    }

    /// The service token rides on downloads, so an uppercase scheme cannot reach another port's origin.
    @Test func uppercaseSchemeDownloadOnAnotherPortIsRefused() throws {
        let gatewayOnPort80 = URL(string: "wss://gateway.example.com:80/")!
        #expect(throws: GatewayFailure.self) {
            try GatewayArtifactLoader.trustedDownloadURL("HTTPS://gateway.example.com/api/artifacts/download/1", endpoint: gatewayOnPort80)
        }
        #expect(try GatewayArtifactLoader.trustedDownloadURL("HTTPS://gateway.example.com:80/api/artifacts/download/1", endpoint: gatewayOnPort80).port == 80)
    }

    @Test func credentialsSavedBeforeAccessSupportStillLoad() throws {
        let saved = #"{"deviceToken":"device","scopes":["operator.read"]}"#
        let credentials = try JSONDecoder().decode(GatewayCredentials.self, from: Data(saved.utf8))
        #expect(credentials.deviceToken == "device")
        #expect(credentials.access == nil)
        let roundTrip = try JSONDecoder().decode(GatewayCredentials.self, from: JSONEncoder().encode(GatewayCredentials(token: "t", access: serviceToken)))
        #expect(roundTrip.access == serviceToken)
    }

    @Test func accessLoginRedirectAsksForTheServiceToken() throws {
        let gateway = URL(string: "https://gateway.example.com/")!
        let login = HTTPURLResponse(url: gateway, statusCode: 302, httpVersion: "HTTP/1.1",
                                    headerFields: ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login/gateway.example.com"])
        #expect(GatewayClient.upgradeRefusal(login)?.code == "ACCESS_REQUIRED")
        let forbidden = HTTPURLResponse(url: gateway, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])
        let refusal = try #require(GatewayClient.upgradeRefusal(forbidden))
        #expect(refusal.code == "UPGRADE_REFUSED")
        #expect(refusal.message.contains("403"))
        #expect(GatewayClient.upgradeRefusal(HTTPURLResponse(url: gateway, statusCode: 101, httpVersion: "HTTP/1.1", headerFields: [:])) == nil)
        #expect(GatewayClient.upgradeRefusal(nil) == nil)
    }
}
