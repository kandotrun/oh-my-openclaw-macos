#if os(macOS)
import Foundation
import Testing
@testable import OhMyOpenClawCore

/// scripts/gateway-fixture.py --signin on a loopback port: a Gateway behind a stand-in for the Cloudflare
/// Access edge, whose origin also plays the team domain and the relay. Its keys and tokens are synthetic,
/// and nothing here leaves this Mac.
private struct AccessSignInGateway {
    let port: Int
    private let process: Process

    var endpoint: URL { URL(string: "ws://127.0.0.1:\(port)/")! }
    var origin: String { "http://127.0.0.1:\(port)" }
    /// The relay and the team domain, both at the fixture's origin.
    var endpoints: CloudflareAccessEndpoints { CloudflareAccessEndpoints.loopbackFixture(URL(string: origin)!)! }

    private init(port: Int, process: Process) { self.port = port; self.process = process }

    static func start() throws -> AccessSignInGateway {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/gateway-fixture.py")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--signin"]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        // Once it listens, the fixture prints its port as its only line.
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); process.waitUntilExit()
            throw GatewayFailure(code: "FIXTURE_NOT_STARTED", message: "gateway-fixture.py --signin printed no port.")
        }
        return AccessSignInGateway(port: port, process: process)
    }

    func stop() { process.terminate(); process.waitUntilExit() }

    /// Signs in as `cloudflared access login` does, with this test as the browser: verify the application,
    /// GET the sign-in link once, as the person approving it would, then take the session from the relay.
    func signIn() async throws -> (CloudflareAccessApplication, CloudflareAccessSession) {
        let application = try await CloudflareAccessSignIn.discover(endpoint, endpoints: endpoints, now: Date())
        let key = CloudflareAccessTransferKey()
        let link = try CloudflareAccessSignIn.signInURL(application, key: key)
        let (_, approval) = try await CloudflareAccessSignIn.liveFetch(URLRequest(url: link), 0)
        #expect(approval.statusCode == 200)
        let session = try await CloudflareAccessSignIn.awaitSession(application, key: key, endpoints: endpoints,
                                                                    deadline: Date().addingTimeInterval(30))
        return (application, session)
    }

    func client(_ credentials: GatewayCredentials) -> GatewayClient {
        GatewayClient(endpoint: endpoint, credentials: credentials, identity: DeviceIdentity())
    }
}

@Suite("Browser sign-in through a loopback Cloudflare Access fixture", .timeLimit(.minutes(1)))
struct CloudflareAccessIntegrationTests {
    @Test("Discover, approve in the stand-in browser, take the session from the relay and connect as the person until Access expires the token")
    func signInConnectsUntilAccessExpiresTheToken() async throws {
        let fixture = try AccessSignInGateway.start()
        defer { fixture.stop() }
        let (application, session) = try await fixture.signIn()
        #expect(application.url.absoluteString == fixture.origin + "/")
        #expect(application.authDomain == "fixture.cloudflareaccess.com")
        #expect(session.gatewayOrigin == fixture.origin)
        #expect(session.authDomain == "fixture.cloudflareaccess.com")
        #expect(session.audience == application.audience)
        #expect(session.subject == "fixture-operator")
        #expect(CloudflareAccessClaims(jwt: session.appToken)?.email == "operator@example.com")

        let credentials = GatewayCredentials(accessSession: session)
        let signedIn = fixture.client(credentials)
        #expect(try await signedIn.connect().payload["protocol"].intValue == 4)
        // Every credential went only where it belongs, and the browser approved one sign-in.
        let audit = try await signedIn.request(method: "fixture.accessAudit", params: .object([:]))
        #expect(audit["leaks"] == .array([]))
        #expect(audit["cliRequests"].intValue == 1)
        // Access ends the session on its side: the open socket outlives it, the next upgrade does not.
        #expect(try await signedIn.request(method: "fixture.expireAccess", params: .object([:]))["expired"].intValue == 1)
        await signedIn.disconnect()

        await #expect {
            _ = try await fixture.client(credentials).connect()
        } throws: { error in
            let failure = error as? GatewayFailure
            return failure?.code == "ACCESS_REQUIRED"
                && failure?.message == "Cloudflare Access のサインインが無効になりました。ブラウザでもう一度サインインしてください。"
        }
    }

    @Test("A service token gets past the Access edge, but the Gateway behind it needs a person")
    func aServiceTokenWithoutAPersonAsksForSignIn() async throws {
        let fixture = try AccessSignInGateway.start()
        defer { fixture.stop() }
        let token = try #require(CloudflareAccessToken(clientID: "fixture-access.access", clientSecret: "fixture-access-secret"))
        await #expect {
            _ = try await fixture.client(GatewayCredentials(access: token)).connect()
        } throws: { error in
            let failure = error as? GatewayFailure
            return failure?.code == "ACCESS_IDENTITY_REQUIRED"
                && failure?.message == "この Gateway は Cloudflare Access のサービストークンでは操作できません。ブラウザで本人のアカウントにサインインしてください。"
        }
        // Without any credential, the edge sends the upgrade to the team's login page.
        await #expect {
            _ = try await fixture.client(GatewayCredentials()).connect()
        } throws: { ($0 as? GatewayFailure)?.code == "ACCESS_REQUIRED" }
    }

    @Test("liveFetch hands back the edge's login redirect with its cookie, and no later request carries the cookie")
    func liveFetchFollowsNoRedirectAndKeepsNoCookie() async throws {
        let fixture = try AccessSignInGateway.start()
        defer { fixture.stop() }
        let plain = URLRequest(url: try #require(URL(string: fixture.origin + "/")))
        let (_, login) = try await CloudflareAccessSignIn.liveFetch(plain, 0)
        #expect(login.statusCode == 302)
        #expect(login.value(forHTTPHeaderField: "Location")?.hasPrefix(fixture.origin + "/cdn-cgi/access/login/") == true)
        #expect(login.value(forHTTPHeaderField: "Set-Cookie")?.hasPrefix("CF_AppSession=") == true)
        // The same request again, then a whole sign-in, all to the origin that set the cookie.
        #expect(try await CloudflareAccessSignIn.liveFetch(plain, 0).1.statusCode == 302)
        let (_, session) = try await fixture.signIn()
        let client = fixture.client(GatewayCredentials(accessSession: session))
        _ = try await client.connect()
        // The fixture records each Cookie header that reaches it.
        #expect(try await client.request(method: "fixture.accessAudit", params: .object([:]))["leaks"] == .array([]))
        await client.disconnect()
    }
}
#endif
