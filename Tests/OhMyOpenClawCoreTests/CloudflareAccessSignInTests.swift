import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import OhMyOpenClawCore

/// Published vectors for the browser sign-in; nothing here is a real credential.
///
/// This app is bob and the relay is alice in the NaCl box2 test (tests/box2.c). The links are
/// cloudflared's `buildRequestURL` (token/transfer.go at ead8b81) run verbatim, and `goBody` is
/// x/crypto nacl/box.Seal from alice to bob with the box2 nonce. The other bodies use the same
/// keys and nonce, sealed by the stdlib Python box that reproduces `goBody` byte for byte.
enum AccessSignInFixture {
    static let audience = AccessSessionFixture.audience
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// bob's public key, padded base64url as cloudflared sends it.
    static let publicKey = "3p7bfXt9wbTTW2HC7OQ1Nz-DQ8hbeGdNrfx-FG-IK08="
    /// alice's public key, as the relay's `service-public-key` header carries it.
    static let senderKey = "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo="
    static var key: CloudflareAccessTransferKey {
        CloudflareAccessTransferKey(privateKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")))
    }

    /// Opens to `{"app_token":"app.token.fixture","org_token":"org.token.fixture"}`.
    static let goBody = "aWlu6VW2K3PNYr2odfxz1oIZ4ANregs3qKLXF2yiSirZDY0+F85PVku8BSoEtpTJZuctjuM1G8VqNZ/iMUozXmpgRCog9zK0CREUocw+6Q48BbbniAbHKXogimHTwoA4XNJ7AiftqSvH"
    /// Opens to `{"app_token": appToken, "org_token": orgToken}`.
    static let body = "aWlu6VW2K3PNYr2odfxz1oIZ4ANregs3kgs/COiVuD1L2iFTEAsIaUu8BSoEtpTJZuctjuM1H8xQc4nKOUYSGUZaaSQctBn/bEAyvt8RxyIeVpGo6FTNE08/nWPt0417YNFNDAfnglrzxk+oStRfpD7uZVGZifC6OO04Z/6BlgTocFmzZhyfSdlPJcf4pRhtdWO0zb8Dvri7gRPEuPUcq9NU1hxu1SFf+T7IcyFxj1yEUSgdPJjq0KqfUSfRrrT9ec2UPBLVnebB6wi7gh5jwAFaTrc4L36ARxkferKWS6bCAwNFZbNCzjuN34+iiPjUw5UcBmmIX0VTQEMwJpk49pYDy/ZVl7+7xDZHLL4G+OQcXI35k7KhBhgLW4BtQUssZwwquuDKjsH7GLz58SNq1Npc1XSVFIZjvhMPpE/DZS8F2GHxYWHXC5xGA88f2C84/DObGh7myyPfy7dx1yxZ7JLqNLTIWYc+k+LrNq/FYhOPcrD9gFDrO5ussGB2i5PZDCH2Mf6M5WfV57Y/ywp+rwCOnc+31DZarddF7GowqfKi5YZJ3autzApl2DtYAEZpxWNvA9W5r3XozV5206x9mtdjjbfLxfRA4Xj3GCpYrh6Y5rPE3N4ETnYHUKB/YnA0ckf5NAqKeQph5FjDLvzFrvFEI5o3I/19wf8vQSUm8u/1YK+SjjcoNw3Vcy3nAkhjiWKu19AJ8LVBJ0rK4YD8OmSLOydeRmZz3+fMIBFWQOYtAtO0fpvfccr4Ohxs9S/04pX4/F9gCrgg/ksQ7DFAIJlBPDdcuElDYIQzgow1DX23CPwWPhXaA+kJMzxE/Ng9ScuIdRLd22WncKOF8DCW6kCCp+yYz2gRFhnRqWujNOVAh0QkUAtkqzO3P8EYFpdTkyZxdrJVDEseULxSs5c26T9GZjOL55cgmYzIAYeCBG2RDTak/FP3MIr+4X29MLViPYe8gUOCZ4GVPsVSlSl4/vAGxxLRzIDqOjxNm4zvKlP0HDog2Eyuw1C/UIULthhIRXcwlJO13dZNYFtJMZT+Ze7cvMcDd136d67v7Ry008eS9S6GDNo9eKGUfn8QDEwHI2RJO5jIeDZyLpWYupEWuLEWOkIS6myg2db7o/EA9coYVNyS3z5AqaDMNVY3NZLRx1hhHg=="
    /// Opens to `{"org_token":"org.token.fixture"}`: an answer without an app token.
    static let orgOnlyBody = "aWlu6VW2K3PNYr2odfxz1oIZ4ANregs3QeoUrF7xrHnycIkm97f8Yku8CygTtpTJZuctjuM1Fcd9NZ/iMUozXmpgRCog9zK0WA=="
    /// A token with `claims` and a placeholder signature: application tokens are read without verification.
    static func token(_ claims: String) -> String {
        [#"{"alg":"RS256","kid":"fixture-rfc7515","typ":"JWT"}"#, claims].map { Data($0.utf8).base64URL }.joined(separator: ".") + ".c2lnbmF0dXJl"
    }
    static let appToken = token(#"{"aud":["\#(audience)"],"email":"operator@example.com","exp":1800086400,"iat":1800000000,"iss":"https://team.cloudflareaccess.com","nbf":1800000000,"sub":"operator-subject","type":"app"}"#)
    /// The same claims as `appToken` with `"type":"org"` and `aud` as a string.
    static let orgToken = token(#"{"aud":"\#(audience)","email":"operator@example.com","exp":1800086400,"iat":1800000000,"iss":"https://team.cloudflareaccess.com","nbf":1800000000,"sub":"operator-subject","type":"org"}"#)
    /// What signing in through `body` to `app()` gives.
    static let session = CloudflareAccessSession(appToken: appToken, gatewayOrigin: "https://gateway.example.com",
                                                 authDomain: "team.cloudflareaccess.com", audience: audience, subject: "operator-subject")!

    static func app(_ url: String = "https://gateway.example.com/openclaw", authDomain: String = "team.cloudflareaccess.com") -> CloudflareAccessApplication {
        CloudflareAccessApplication(url: URL(string: url)!, authDomain: authDomain, audience: audience)
    }

    static func transfer(_ body: String, senderKey: String? = senderKey) -> ScriptedFetch.Answer {
        .status(200, headers: senderKey.map { ["service-public-key": $0] } ?? [:], body: Data(body.utf8))
    }

    static func hex(_ string: String) -> Data {
        var bytes = [UInt8](); var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!); index = next
        }
        return Data(bytes)
    }
}

/// Answers each request with the next scripted answer, repeating the last, and records every request.
actor ScriptedFetch {
    enum Answer: Sendable {
        case status(Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError.Code)
    }

    private var script: [Answer]
    private(set) var requests: [URLRequest] = []
    private(set) var limits: [Int] = []

    init(_ script: [Answer]) { self.script = script }

    func fetch(_ request: URLRequest, _ maxBytes: Int) throws -> (Data, HTTPURLResponse) {
        requests.append(request); limits.append(maxBytes)
        let answer = script.count > 1 ? script.removeFirst() : script[0]
        switch answer {
        case .failure(let code): throw URLError(code)
        case .status(let status, let headers, let body):
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }
}

/// Time that moves only when the code under test pauses, so no test waits on the wall clock.
final class TestClock: Sendable {
    private let state: Mutex<(now: Date, pauses: [Duration])>

    init(_ start: Date = AccessSignInFixture.now) { state = Mutex((start, [])) }

    var pauses: [Duration] { state.withLock { $0.pauses } }
    func now() -> Date { state.withLock { $0.now } }
    func pause(_ duration: Duration) {
        state.withLock {
            $0.now += Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
            $0.pauses.append(duration)
        }
    }
}

/// The code of the `GatewayFailure` that `body` throws; nil when it throws anything else or returns.
func failureCode<Value>(_ body: () async throws -> Value) async -> String? {
    do { _ = try await body(); return nil } catch { return (error as? GatewayFailure)?.code }
}

private func paddedBase64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}

@Suite("Cloudflare Access browser sign-in")
struct CloudflareAccessSignInTests {
    private typealias Fixture = AccessSignInFixture

    private func signIn(_ relay: ScriptedFetch, app: CloudflareAccessApplication = Fixture.app(), clock: TestClock = TestClock(),
                        deadline: TimeInterval = 300, endpoints: CloudflareAccessEndpoints = .cloudflare) async throws -> CloudflareAccessSession {
        try await CloudflareAccessSignIn.awaitSession(app, key: Fixture.key, endpoints: endpoints, deadline: clock.now() + deadline,
                                                      now: { clock.now() }, pause: { clock.pause($0) }) { try await relay.fetch($0, $1) }
    }

    // MARK: The browser link

    @Test func transferKeyIsAPaddedBase64URLPublicKey() {
        let key = Fixture.key
        #expect(key.publicKey == "3p7bfXt9wbTTW2HC7OQ1Nz-DQ8hbeGdNrfx-FG-IK08=")
        #expect(Data(base64URL: key.publicKey) == Fixture.hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
        let fresh = CloudflareAccessTransferKey(), other = CloudflareAccessTransferKey()
        #expect(fresh.publicKey != other.publicKey)
        for text in [fresh.publicKey, other.publicKey] {
            #expect(text.utf8.count == 44 && text.hasSuffix("="))
            #expect(text.dropLast().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        }
    }

    @Test func signInLinksMatchCloudflaredByteForByte() throws {
        let aud = Fixture.audience, token = String(Fixture.publicKey.dropLast())
        let root = try CloudflareAccessSignIn.signInURL(Fixture.app("https://gateway.example.com/"), key: Fixture.key)
        #expect(root.absoluteString == "https://gateway.example.com/cdn-cgi/access/cli?aud=\(aud)&close_interstitial=true&edge_token_transfer=true&redirect_url=https%3A%2F%2Fgateway.example.com%2F%3Faud%3D\(aud)%26token%3D\(token)%253D&send_org_token=true&token=\(token)%3D")
        let prefixed = try CloudflareAccessSignIn.signInURL(Fixture.app("https://gateway.example.com/openclaw"), key: Fixture.key)
        #expect(prefixed.absoluteString == "https://gateway.example.com/cdn-cgi/access/cli?aud=\(aud)&close_interstitial=true&edge_token_transfer=true&redirect_url=https%3A%2F%2Fgateway.example.com%2Fopenclaw%3Faud%3D\(aud)%26token%3D\(token)%253D&send_org_token=true&token=\(token)%3D")
        let staysOpen = try CloudflareAccessSignIn.signInURL(Fixture.app("https://gateway.example.com/"), key: Fixture.key, closeInterstitial: false)
        #expect(staysOpen.absoluteString == "https://gateway.example.com/cdn-cgi/access/cli?aud=\(aud)&edge_token_transfer=true&redirect_url=https%3A%2F%2Fgateway.example.com%2F%3Faud%3D\(aud)%26token%3D\(token)%253D&send_org_token=true&token=\(token)%3D")
        let port = try CloudflareAccessSignIn.signInURL(Fixture.app("https://gateway.example.com:8443/openclaw/"), key: Fixture.key)
        #expect(port.absoluteString == "https://gateway.example.com:8443/cdn-cgi/access/cli?aud=\(aud)&close_interstitial=true&edge_token_transfer=true&redirect_url=https%3A%2F%2Fgateway.example.com%3A8443%2Fopenclaw%2F%3Faud%3D\(aud)%26token%3D\(token)%253D&send_org_token=true&token=\(token)%3D")
    }

    @Test func formEncodingIsGoURLValuesEncode() {
        #expect(CloudflareAccessSignIn.formEncode([("token", "a=b&c"), ("aud", "A-z.0_9~")]) == "aud=A-z.0_9~&token=a%3Db%26c")
        #expect(CloudflareAccessSignIn.formEncode([("q", "a b/é?#%+")]) == "q=a+b%2F%C3%A9%3F%23%25%2B")
        #expect(CloudflareAccessSignIn.formEncode([]) == "")
    }

    @Test func applicationURLIsTheGatewayEndpointOverHTTPS() throws {
        for (endpoint, application) in [("wss://gateway.example.com/", "https://gateway.example.com/"),
                                        ("wss://gateway.example.com:8443/openclaw", "https://gateway.example.com:8443/openclaw"),
                                        ("wss://Gateway.Example.com/openclaw/", "https://gateway.example.com/openclaw/"),
                                        ("https://gateway.example.com/openclaw", "https://gateway.example.com/openclaw"),
                                        ("ws://127.0.0.1:61234/", "http://127.0.0.1:61234/"),
                                        ("ws://localhost:8080/gateway", "http://localhost:8080/gateway"),
                                        ("ws://[::1]:8080/", "http://[::1]:8080/")] {
            let url = try #require(URL(string: endpoint))
            #expect(try CloudflareAccessSignIn.applicationURL(for: url).absoluteString == application, "\(endpoint)")
        }
        for endpoint in ["ws://gateway.example.com/", "http://gateway.example.com/", "wss://user@gateway.example.com/",
                         "wss://gateway.example.com/?x=1", "ftp://gateway.example.com/"] {
            let url = try #require(URL(string: endpoint))
            #expect(throws: GatewayFailure.self, "\(endpoint)") { try CloudflareAccessSignIn.applicationURL(for: url) }
        }
    }

    // MARK: Waiting for the relay

    @Test func pollsTheRelayWithOnlyThePublicKeyUntilTheTransferArrives() async throws {
        let relay = ScriptedFetch([.status(404), .status(404), Fixture.transfer(Fixture.body)])
        let clock = TestClock()
        #expect(try await signIn(relay, clock: clock) == Fixture.session)
        let requests = await relay.requests
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.url?.absoluteString == "https://login.cloudflareaccess.org/transfer/3p7bfXt9wbTTW2HC7OQ1Nz-DQ8hbeGdNrfx-FG-IK08=")
            #expect(request.httpMethod == "GET")
            // No Cookie, Authorization, Cf-Access-Token or service token: the relay learns only the public key.
            #expect((request.allHTTPHeaderFields ?? [:]).isEmpty)
            #expect(request.httpBody == nil)
            #expect(request.timeoutInterval == 65)
        }
        #expect(await relay.limits == [65_536, 65_536, 65_536])
        #expect(clock.pauses == [.seconds(1), .seconds(1)])
    }

    @Test func theSessionKeepsTheAppTokenAndNeverTheOrgToken() async throws {
        let session = try await signIn(ScriptedFetch([Fixture.transfer(Fixture.body)]))
        #expect(session.appToken == Fixture.appToken)
        #expect(session.gatewayOrigin == "https://gateway.example.com")
        #expect(session.authDomain == "team.cloudflareaccess.com")
        #expect(session.audience == Fixture.audience)
        #expect(session.subject == "operator-subject")
        let saved = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(!saved.contains(Fixture.orgToken.split(separator: ".")[1]))
    }

    @Test(arguments: [500, 502, 503, 401, 403])
    func relayErrorsAndRefusalsEndTheSignIn(status: Int) async {
        let relay = ScriptedFetch([.status(status), Fixture.transfer(Fixture.body)])
        let clock = TestClock()
        #expect(await failureCode { try await signIn(relay, clock: clock) } == "ACCESS_TRANSFER_FAILED")
        #expect(await relay.requests.count == 1)
        #expect(clock.pauses.isEmpty)
    }

    @Test(arguments: [404, 400, 302, 429, 204])
    func otherAnswersMeanTheBrowserIsNotDoneYet(status: Int) async throws {
        // An empty 200 is not a transfer either.
        let relay = ScriptedFetch([.status(status), .status(200), Fixture.transfer(Fixture.body)])
        let clock = TestClock()
        #expect(try await signIn(relay, clock: clock) == Fixture.session)
        #expect(await relay.requests.count == 3)
        #expect(clock.pauses == [.seconds(1), .seconds(1)])
    }

    @Test func briefNetworkErrorsBackOffAndPollAgain() async throws {
        // URLSession usually reports a failed DNS lookup as cannotFindHost (-1003).
        let relay = ScriptedFetch([.failure(.timedOut), .failure(.networkConnectionLost), .failure(.notConnectedToInternet),
                                   .failure(.cannotConnectToHost), .failure(.cannotFindHost), .failure(.dnsLookupFailed),
                                   Fixture.transfer(Fixture.body)])
        let clock = TestClock()
        #expect(try await signIn(relay, clock: clock) == Fixture.session)
        #expect(await relay.requests.count == 7)
        #expect(clock.pauses == [.seconds(1), .seconds(2), .seconds(2), .seconds(2), .seconds(2), .seconds(2)])
    }

    @Test func anAnswerFromTheRelayResetsTheBackoff() async throws {
        let relay = ScriptedFetch([.failure(.networkConnectionLost), .failure(.networkConnectionLost), .status(404),
                                   .failure(.networkConnectionLost), Fixture.transfer(Fixture.body)])
        let clock = TestClock()
        #expect(try await signIn(relay, clock: clock) == Fixture.session)
        #expect(clock.pauses == [.seconds(1), .seconds(2), .seconds(1), .seconds(1)])
    }

    @Test(arguments: [URLError.Code.badServerResponse, .secureConnectionFailed, .serverCertificateUntrusted, .cannotParseResponse, .cancelled, .badURL])
    func otherTransportErrorsEndTheSignIn(code: URLError.Code) async {
        let relay = ScriptedFetch([.failure(code), Fixture.transfer(Fixture.body)])
        #expect(await failureCode { try await signIn(relay) } == "ACCESS_TRANSFER_FAILED")
        #expect(await relay.requests.count == 1)
    }

    @Test func theSignInTimesOutAtTheDeadline() async {
        let relay = ScriptedFetch([.status(404)])
        let clock = TestClock()
        #expect(await failureCode { try await signIn(relay, clock: clock, deadline: 5) } == "ACCESS_SIGN_IN_TIMEOUT")
        #expect(await relay.requests.count == 5)
        #expect(clock.pauses == Array(repeating: .seconds(1), count: 5))

        let offline = ScriptedFetch([.failure(.notConnectedToInternet)])
        let offlineClock = TestClock()
        #expect(await failureCode { try await signIn(offline, clock: offlineClock, deadline: 5) } == "ACCESS_SIGN_IN_TIMEOUT")
        #expect(await offline.requests.count == 3)
        #expect(offlineClock.pauses == [.seconds(1), .seconds(2), .seconds(2)])

        let late = ScriptedFetch([Fixture.transfer(Fixture.body)])
        #expect(await failureCode { try await signIn(late, deadline: 0) } == "ACCESS_SIGN_IN_TIMEOUT")
        #expect(await late.requests.isEmpty)
    }

    @Test func pollsNeverOutlastTheDeadline() async throws {
        let relay = ScriptedFetch([.status(404), Fixture.transfer(Fixture.body)])
        #expect(try await signIn(relay, deadline: 20) == Fixture.session)
        #expect(await relay.requests.map(\.timeoutInterval) == [20, 19])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringAPollEndsWithCancellationError() async {
        let (polled, poll) = AsyncStream.makeStream(of: Void.self)
        let (gate, gateKeeper) = AsyncStream.makeStream(of: Never.self)
        let clock = TestClock()
        let task = Task {
            try await CloudflareAccessSignIn.awaitSession(Fixture.app(), key: Fixture.key, deadline: clock.now() + 300,
                                                          now: { clock.now() }, pause: { clock.pause($0) }) { _, _ in
                poll.yield()
                for await _ in gate {}          // Ends only when the sign-in task is cancelled.
                throw URLError(.cancelled)      // What URLSession throws for a cancelled request.
            }
        }
        for await _ in polled { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        gateKeeper.finish()
    }

    @Test func cancellingDuringAPauseOrBeforeTheFirstPollEndsWithCancellationError() async {
        let relay = ScriptedFetch([.status(404)])
        await #expect(throws: CancellationError.self) {
            try await CloudflareAccessSignIn.awaitSession(Fixture.app(), key: Fixture.key, deadline: Fixture.now + 300,
                                                          now: { Fixture.now }, pause: { _ in throw CancellationError() }) { try await relay.fetch($0, $1) }
        }
        #expect(await relay.requests.count == 1)

        let unused = ScriptedFetch([Fixture.transfer(Fixture.body)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CloudflareAccessSignIn.awaitSession(Fixture.app(), key: Fixture.key, deadline: Fixture.now + 300,
                                                                 now: { Fixture.now }, pause: { _ in }) { try await unused.fetch($0, $1) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await unused.requests.isEmpty)
    }

    @Test func fedRAMPTeamsPollTheFedRAMPRelay() async throws {
        for (team, relayURL) in [("team.fed.cloudflareaccess.com", "https://login.fed.cloudflareaccess.org/transfer/"),
                                 ("team.cloudflareaccess.com", "https://login.cloudflareaccess.org/transfer/"),
                                 ("fed.cloudflareaccess.com", "https://login.cloudflareaccess.org/transfer/")] {
            let relay = ScriptedFetch([.status(503)])
            _ = await failureCode { try await signIn(relay, app: Fixture.app(authDomain: team)) }
            #expect(await relay.requests.map(\.url?.absoluteString) == [relayURL + Fixture.publicKey], "\(team)")
        }
        let origin = try #require(URL(string: "http://127.0.0.1:61234"))
        let fixture = try #require(CloudflareAccessEndpoints.loopbackFixture(origin))
        for team in ["team.cloudflareaccess.com", "team.fed.cloudflareaccess.com"] {
            let relay = ScriptedFetch([.status(503)])
            _ = await failureCode { try await signIn(relay, app: Fixture.app(authDomain: team), endpoints: fixture) }
            #expect(await relay.requests.map(\.url?.absoluteString) == ["http://127.0.0.1:61234/transfer/" + Fixture.publicKey], "\(team)")
        }
    }

    @Test func loopbackFixturesStandInForTheRelayAndTheTeamDomain() throws {
        #expect(CloudflareAccessEndpoints.cloudflare.relay.absoluteString == "https://login.cloudflareaccess.org/")
        #expect(CloudflareAccessEndpoints.cloudflare.fedRelay.absoluteString == "https://login.fed.cloudflareaccess.org/")
        #expect(CloudflareAccessEndpoints.cloudflare.teamDomainOrigin == nil)
        for origin in ["http://127.0.0.1:61234", "http://127.0.0.1:61234/", "http://localhost:8080", "http://[::1]:8080"] {
            let url = try #require(URL(string: origin))
            let endpoints = try #require(CloudflareAccessEndpoints.loopbackFixture(url), "\(origin)")
            let root = origin.hasSuffix("/") ? origin : origin + "/"
            #expect(endpoints.relay.absoluteString == root)
            #expect(endpoints.fedRelay.absoluteString == root)
            #expect(endpoints.teamDomainOrigin?.absoluteString == String(root.dropLast()))
        }
        for origin in ["https://127.0.0.1:61234", "ws://127.0.0.1:61234", "http://gateway.example.com:61234", "http://127.0.0.2:61234",
                       "http://user@127.0.0.1:61234", "http://127.0.0.1:61234/relay", "http://127.0.0.1:61234/?x=1", "http://127.0.0.1:61234/#x"] {
            #expect(CloudflareAccessEndpoints.loopbackFixture(try #require(URL(string: origin))) == nil, "\(origin)")
        }
    }

    // MARK: Opening the transfer

    @Test func theGoSealedTransferOpensWithTheRelayKey() throws {
        #expect(try CloudflareAccessSignIn.openTransfer(body: Data(Fixture.goBody.utf8), senderKey: Fixture.senderKey, key: Fixture.key) == "app.token.fixture")
        // ASCII whitespace in the base64 body and an unpadded sender key are accepted.
        let wrapped = "\n " + Fixture.goBody.prefix(40) + "\r\n\t" + Fixture.goBody.dropFirst(40) + "\n"
        #expect(try CloudflareAccessSignIn.openTransfer(body: Data(wrapped.utf8), senderKey: String(Fixture.senderKey.dropLast()), key: Fixture.key) == "app.token.fixture")
    }

    @Test func aTransferThatCannotBeOpenedFails() async throws {
        let body = Data(Fixture.goBody.utf8)
        let sealed = try #require(Data(base64Encoded: Fixture.goBody))
        let alice = try #require(Data(base64URL: Fixture.senderKey))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        let cases: [(String, Data, String?)] = [
            ("tampered", Data(tampered.base64EncodedString().utf8), Fixture.senderKey),
            ("no sender key", body, nil),
            ("empty sender key", body, ""),
            ("31-byte sender key", body, paddedBase64URL(alice.prefix(31))),
            ("33-byte sender key", body, paddedBase64URL(alice + [0])),
            ("standard base64 sender key", body, Fixture.senderKey.replacingOccurrences(of: "_", with: "/")),
            ("low-order sender key", body, String(repeating: "A", count: 43) + "="),
            ("another sender", body, Fixture.publicKey),
            ("not base64", Data("not base64!".utf8), Fixture.senderKey),
            ("truncated", Data(Fixture.goBody.dropLast(4).utf8), Fixture.senderKey),
            ("no app token", Data(Fixture.orgOnlyBody.utf8), Fixture.senderKey),
        ]
        for (name, body, senderKey) in cases {
            let code = await failureCode { try CloudflareAccessSignIn.openTransfer(body: body, senderKey: senderKey, key: Fixture.key) }
            #expect(code == "ACCESS_TRANSFER_FAILED", "\(name)")
        }
    }

    @Test func aTransferThatFailsToOpenOrValidateEndsTheSignInAtOnce() async throws {
        let sealed = try #require(Data(base64Encoded: Fixture.body))
        var tampered = sealed
        tampered[40] ^= 1
        // Whitespace is skipped, so this body would open if the 64 KiB cap did not stop it first.
        let oversized = Fixture.body + String(repeating: " ", count: 65_536)
        let cases: [(String, ScriptedFetch.Answer, String)] = [
            ("tampered", Fixture.transfer(tampered.base64EncodedString()), "ACCESS_TRANSFER_FAILED"),
            ("no sender key", Fixture.transfer(Fixture.body, senderKey: nil), "ACCESS_TRANSFER_FAILED"),
            ("over 64 KiB", Fixture.transfer(oversized), "ACCESS_TRANSFER_FAILED"),
            // It opens, but its placeholder app token is no JWT.
            ("not a token", Fixture.transfer(Fixture.goBody), "ACCESS_TOKEN_INVALID"),
        ]
        for (name, answer, code) in cases {
            let relay = ScriptedFetch([answer, Fixture.transfer(Fixture.body)])
            #expect(await failureCode { try await signIn(relay) } == code, "\(name)")
            #expect(await relay.requests.count == 1, "\(name)")
        }
    }

    // MARK: Checking the app token

    @Test func theAppTokenMustBeForThisApplicationAndStillValid() async throws {
        let app = Fixture.app()
        let now = Fixture.now
        func token(header: JSONValue = AccessSessionFixture.rs256, _ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> String {
            var claims = AccessSessionFixture.appClaims
            edit(&claims)
            return AccessSessionFixture.jwt(header: header, claims: claims)
        }
        func check(_ token: String) async -> String? {
            await failureCode { try CloudflareAccessSignIn.validatedSession(appToken: token, for: app, now: now) }
        }
        let issued = token()
        let valid = try CloudflareAccessSignIn.validatedSession(appToken: issued, for: app, now: now)
        #expect(valid.appToken == issued)
        #expect(valid.gatewayOrigin == "https://gateway.example.com")
        #expect(valid.authDomain == "team.cloudflareaccess.com")
        #expect(valid.audience == Fixture.audience)
        #expect(valid.subject == "operator-subject")

        let accepted: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("aud string", { $0["aud"] = .string(Fixture.audience) }),
            ("aud array with others", { $0["aud"] = .array([.string("other"), .string(Fixture.audience)]) }),
            ("expires in a second", { $0["exp"] = .number(now.timeIntervalSince1970 + 1) }),
            ("valid in a minute", { $0["nbf"] = .number(now.timeIntervalSince1970 + 60) }),
            ("no nbf", { $0["nbf"] = nil }), ("no email", { $0["email"] = nil }),
            ("512-byte sub", { $0["sub"] = .string(String(repeating: "s", count: 512)) }),
        ]
        for (name, edit) in accepted {
            #expect(throws: Never.self, "\(name)") { try CloudflareAccessSignIn.validatedSession(appToken: token(edit), for: app, now: now) }
        }

        let rejected: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("type org", { $0["type"] = .string("org") }), ("no type", { $0["type"] = nil }),
            ("other aud", { $0["aud"] = .string("other") }), ("aud array without ours", { $0["aud"] = .array([.string("other")]) }),
            ("no aud", { $0["aud"] = nil }),
            ("other team", { $0["iss"] = .string("https://other.cloudflareaccess.com") }),
            ("iss without scheme", { $0["iss"] = .string("team.cloudflareaccess.com") }),
            ("iss with path", { $0["iss"] = .string("https://team.cloudflareaccess.com/") }),
            ("iss over http", { $0["iss"] = .string("http://team.cloudflareaccess.com") }),
            ("expired now", { $0["exp"] = .number(now.timeIntervalSince1970) }),
            ("expired", { $0["exp"] = .number(now.timeIntervalSince1970 - 1) }),
            ("not yet valid", { $0["nbf"] = .number(now.timeIntervalSince1970 + 61) }),
            ("no sub", { $0["sub"] = nil }), ("empty sub", { $0["sub"] = .string("") }),
            ("long sub", { $0["sub"] = .string(String(repeating: "s", count: 513)) }),
            ("sub with a line break", { $0["sub"] = .string("operator\nsubject") }),
            ("sub not a string", { $0["sub"] = .number(1) }),
        ]
        for (name, edit) in rejected {
            #expect(await check(token(edit)) == "ACCESS_TOKEN_INVALID", "\(name)")
        }
        for header: JSONValue in [.object(["alg": .string("none")]), .object(["alg": .string("HS256")]), .object(["kid": .string("fixture-key")])] {
            #expect(await check(token(header: header)) == "ACCESS_TOKEN_INVALID", "\(header)")
        }
        let padded = token { $0["padding"] = .string(String(repeating: "x", count: 16 * 1024)) }
        for bad in [issued + "=", issued.replacingOccurrences(of: "-", with: "+") + "+", issued + "\n", issued + ".extra", padded] {
            #expect(await check(bad) == "ACCESS_TOKEN_INVALID", "\(bad.suffix(12).debugDescription)")
        }
    }

    @Test func aLoopbackApplicationSignsInForItsOwnOrigin() throws {
        let app = Fixture.app("http://127.0.0.1:61234/")
        let session = try CloudflareAccessSignIn.validatedSession(appToken: Fixture.appToken, for: app, now: Fixture.now)
        #expect(session.gatewayOrigin == "http://127.0.0.1:61234")
    }

    // MARK: Messages

    @Test func everyFailureHasAConstantMessage() {
        let messages = Dictionary(uniqueKeysWithValues: CloudflareAccessSignIn.Failure.allCases.map { ($0.error.code, $0.error.message) })
        #expect(messages == [
            "ACCESS_NOT_PROTECTED": "この URL では Cloudflare Access のアプリを確認できませんでした。URL と、Gateway が Cloudflare Access で保護されているかを確認してください。",
            "ACCESS_UNREACHABLE": "Cloudflare Access に接続できませんでした。ネットワークを確認して、もう一度お試しください。",
            "ACCESS_METADATA_INVALID": "Cloudflare Access の応答を検証できなかったため、サインインを中止しました。URL を確認してください。",
            "ACCESS_TRANSFER_FAILED": "Cloudflare Access からサインイン情報を受け取れませんでした。もう一度サインインしてください。",
            "ACCESS_SIGN_IN_TIMEOUT": "5 分以内にサインインが完了しませんでした。もう一度サインインしてください。",
            "ACCESS_TOKEN_INVALID": "受け取ったサインイン情報がこの Gateway のものではないか、有効期限が切れています。もう一度サインインしてください。",
        ])
    }
}
