import CryptoKit
import Foundation
import Synchronization
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

// MARK: - Fixtures

/// Synthetic Cloudflare Access sign-ins to one Gateway. The tokens carry readable claims and a
/// placeholder signature: nothing here is a real credential.
private enum Fixture {
    static let gateway = "wss://gateway.example.com/"
    static let gatewayURL = URL(string: gateway)!
    static let other = "wss://other.example.com/"
    static let otherURL = URL(string: other)!
    static let team = "team.cloudflareaccess.com"
    static let audience = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    static let link = URL(string: "https://gateway.example.com/cdn-cgi/access/cli?token=synthetic-public-key")!
    static let serviceToken = CloudflareAccessToken(clientID: "client.access", clientSecret: "client-secret")!
    static let expiredMessage = "Cloudflare Access のサインインの有効期限が切れました。ブラウザでもう一度サインインしてください。"
    static let couldNotConnectMessage = "サインインは完了しましたが、Gateway への接続を始められませんでした。もう一度サインインしてください。"
    static let pairingMessage = "Gateway 側でこの端末を承認してから、再接続してください。"
    static let refusedMessage = "Cloudflare Access のサインインが無効になりました。ブラウザでもう一度サインインしてください。"

    static func session(subject: String = "person-a", email: String? = "person-a@example.com",
                        expiresAt: Date = Date(timeIntervalSince1970: 1_900_000_000),
                        origin: String = "https://gateway.example.com") -> CloudflareAccessSession {
        var claims: [String: JSONValue] = [
            "type": .string("app"), "aud": .array([.string(audience)]), "iss": .string("https://" + team),
            "sub": .string(subject), "exp": .number(expiresAt.timeIntervalSince1970),
        ]
        if let email { claims["email"] = .string(email) }
        let token = segment(.object(["alg": .string("RS256"), "kid": .string("fixture-key")])) + "." + segment(.object(claims)) + ".c2lnbmF0dXJl"
        return CloudflareAccessSession(appToken: token, gatewayOrigin: origin, authDomain: team, audience: audience, subject: subject)!
    }

    static func setupCode(expiresAt: Date? = nil) -> String {
        var payload: [String: JSONValue] = ["url": .string(gateway), "bootstrapToken": .string("fresh-bootstrap")]
        if let expiresAt { payload["expiresAtMs"] = .number((expiresAt.timeIntervalSince1970 * 1000).rounded()) }
        return base64URL(try! JSONEncoder().encode(JSONValue.object(payload)))
    }

    static func key(_ endpoint: String) -> String { "gateway:" + digest(endpoint) }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func segment(_ value: JSONValue) -> String { base64URL(try! JSONEncoder().encode(value)) }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Stands in for the browser sign-in: it records the Gateway, shows a link, then waits until the
/// test finishes the sign-in or the sign-in is cancelled. It gives up after ten seconds, so a test
/// whose sign-in cannot be cancelled fails instead of hanging.
@MainActor private final class FakeBrowserSignIn {
    var opened = true
    /// Thrown before any link is shown, as a failed discovery would be.
    var discoveryFailure: GatewayFailure?
    /// Runs as each sign-in starts.
    var onStart: (() -> Void)?
    private(set) var gateways: [URL] = []
    private(set) var linksShown = 0
    private var outcome: Result<CloudflareAccessSession, any Error>?
    private let shown = AsyncStream<Void>.makeStream()

    var authenticator: CloudflareAccessAuthenticator {
        CloudflareAccessAuthenticator(signIn: { gateway, showLink in try await self.signIn(gateway, showLink: showLink) })
    }

    func waitForBrowser() async { for await _ in shown.stream { return } }
    func finish(_ session: CloudflareAccessSession) { outcome = .success(session) }

    private func signIn(_ gateway: URL, showLink: @MainActor (URL, Bool, String, String) -> Void) async throws -> CloudflareAccessSession {
        gateways.append(gateway)
        onStart?()
        if let discoveryFailure { throw discoveryFailure }
        showLink(Fixture.link, opened, "gateway.example.com", Fixture.team)
        linksShown += 1
        shown.continuation.yield()
        let abandoned = ContinuousClock.now + .seconds(10)
        while outcome == nil {
            guard ContinuousClock.now < abandoned else { throw GatewayFailure(code: "FAKE_BROWSER_ABANDONED", message: "The test never finished the sign-in.") }
            try await Task.sleep(for: .milliseconds(1))
        }
        defer { outcome = nil }
        return try outcome!.get()
    }
}

/// A wall clock the test sets, and sleeps that last until the test fires them or their task is cancelled.
@MainActor private final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [Duration] = []
    private var sleepers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let slept = AsyncStream<Void>.makeStream()

    func sleep(_ duration: Duration) async throws {
        sleeps.append(duration)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleepers[id] = $0; slept.continuation.yield() }
        } onCancel: {
            Task { @MainActor in self.wake(id) }
        }
        try Task.checkCancellation()
    }

    func waitForSleep() async { for await _ in slept.stream { return } }
    func fire() { let woken = sleepers; sleepers = [:]; for sleeper in woken.values { sleeper.resume() } }
    private func wake(_ id: UUID) { sleepers.removeValue(forKey: id)?.resume() }
}

/// A Gateway that admits the connect, or refuses it with `failure`, and can hold the connect until
/// the test releases it.
private actor SignInGateway: GatewayServing {
    private let failure: GatewayFailure?
    private let issuedDeviceToken: String?
    private var holding: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private let started = AsyncStream<Void>.makeStream()
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private(set) var disconnectCount = 0

    init(failure: GatewayFailure? = nil, issuedDeviceToken: String? = nil, holdConnect: Bool = false) {
        self.failure = failure; self.issuedDeviceToken = issuedDeviceToken; holding = holdConnect
    }

    func connect() async throws -> GatewayHello {
        if holding { await withCheckedContinuation { waiter = $0; started.continuation.yield() } }
        if let failure { throw failure }
        var payload: [String: JSONValue] = ["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("a"), "mainSessionKey": .string("agent:a:main"),
        ])])]
        if let issuedDeviceToken { payload["auth"] = .object(["deviceToken": .string(issuedDeviceToken)]) }
        return GatewayHello(payload: .object(payload))
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let channel = AsyncStream<GatewayEvent>.makeStream()
        continuation = channel.continuation
        return channel.stream
    }
    func disconnect() async { disconnectCount += 1; continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        method == "chat.history" ? .object(["sessionId": .string("physical"), "messages": .array([])]) : .object([:])
    }
    func waitForConnect() async { for await _ in started.stream { return } }
    func releaseConnect() { holding = false; waiter?.resume(); waiter = nil }
    func dropConnection() { continuation?.yield(GatewayEvent(name: "client.disconnected")) }
}

/// One Gateway's conversations on disk. Each opening drops saves older than its newest, as
/// ConversationPersistence does.
private final class ConversationFile: Sendable {
    private let saved: Mutex<ConversationStore>
    init(_ state: ConversationStore = ConversationStore()) { saved = Mutex(state) }
    var state: ConversationStore { saved.withLock { $0 } }
    func open() -> any ConversationPersisting { Opening(file: self) }
    fileprivate func write(_ state: ConversationStore) { saved.withLock { $0 = state } }

    private actor Opening: ConversationPersisting {
        let file: ConversationFile
        private var newestRevision = -1
        init(file: ConversationFile) { self.file = file }
        func load() throws -> ConversationStore { file.state }
        func save(_ state: ConversationStore, revision: Int) throws {
            guard revision > newestRevision else { return }
            newestRevision = revision
            file.write(state)
        }
    }
}

/// Credentials in memory, the Gateways and conversation files the test sets up, and the clock it controls.
@MainActor private final class SignInEnvironment {
    var credentials: [String: GatewayCredentials] = [:]
    private(set) var made: [(endpoint: String, credentials: GatewayCredentials)] = []
    /// Gateways handed out per endpoint, in order; the last one serves every later connect.
    var gateways: [String: [SignInGateway]] = [:]
    /// Sees each credential write before it lands, and refuses it by throwing.
    var onWrite: ((GatewayCredentials) throws -> Void)?
    /// Thrown in place of making a service, as when the device identity cannot be read.
    var serviceFailure: GatewayFailure?
    let browser = FakeBrowserSignIn()
    let clock = ManualClock()

    var access: GatewayConnectionAccess {
        var access = GatewayConnectionAccess(
            read: { self.credentials[$0] },
            write: { value, key in try self.onWrite?(value); self.credentials[key] = value },
            delete: { self.credentials[$0] = nil },
            makeService: { url, value in
                if let failure = self.serviceFailure { throw failure }
                self.made.append((url.absoluteString, value))
                return self.gateway(for: url.absoluteString)
            })
        access.accessAuthenticator = browser.authenticator
        access.now = { self.clock.now }
        access.sleep = { [clock] in try await clock.sleep($0) }
        return access
    }

    func gateway(for endpoint: String) -> SignInGateway {
        var queue = gateways[endpoint] ?? [SignInGateway()]
        let next = queue.count > 1 ? queue.removeFirst() : queue[0]
        gateways[endpoint] = queue
        return next
    }
}

/// An app whose saved Gateways are `saved`, the last one active.
@MainActor private struct SignInHarness {
    let environment = SignInEnvironment()
    let app: AppModel

    init(saved: [String] = [], files: [String: ConversationFile] = [:]) throws {
        var profiles = GatewayProfiles()
        for endpoint in saved { try profiles.activate(try #require(URL(string: endpoint))) }
        let byNamespace = Dictionary(uniqueKeysWithValues: files.map { (Fixture.digest($0.key), $0.value) })
        app = AppModel(persistenceFactory: { (byNamespace[$0] ?? ConversationFile()).open() },
                       profileRepository: TestGatewayProfileRepository(profiles), connectionAccess: environment.access)
    }

    func signIn(_ urlText: String = Fixture.gateway, setupCode: String = "", alias: String? = nil) -> Task<Void, Never> {
        Task { await app.signInWithCloudflareAccess(urlText: urlText, secret: "", password: false, setupCode: setupCode, alias: alias) }
    }

    /// Signs in to `Fixture.gateway` as `session`, through the browser.
    func signIn(as session: CloudflareAccessSession) async {
        let signingIn = signIn()
        await environment.browser.waitForBrowser()
        environment.browser.finish(session)
        await signingIn.value
    }
}

@MainActor private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("The condition never held.", sourceLocation: sourceLocation); return }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// What person A left on this Mac for the Gateway.
private func personACache() -> ConversationStore {
    var store = ConversationStore()
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "メインチャット", isMain: true)
    store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "A's draft"), for: main.id)
    store.transcripts[main.id] = [ChatMessage(id: "a-1", role: .user, text: "A's message")]
    store.pending["run-a"] = PendingSubmission(id: "run-a", target: main, params: .object([:]),
                                               message: ChatMessage(id: "run-a", role: .user, text: "A's queued message", delivery: .uncertain, runID: "run-a"))
    store.viewerProfileID = "profile-a"
    return store
}

/// What this Mac cached for another Gateway: its main chat with a draft.
private func otherGatewayCache() -> ConversationStore {
    var store = ConversationStore()
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "メインチャット", isMain: true)
    store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "Other's draft"), for: main.id)
    return store
}

// MARK: - Signing in

// The limit cancels a test left waiting on a fixture that never answers.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccessSignInTests {
    @Test(arguments: [true, false])
    func signingInFromTheFormSavesTheSessionInPlaceOfTheServiceTokenAndConnects(browserOpened: Bool) async throws {
        let h = try SignInHarness()
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(deviceToken: "paired-before", scopes: ["operator.read"], access: Fixture.serviceToken)
        h.environment.browser.opened = browserOpened
        var stateAtStart: CloudflareAccessSignInState?, stateAtWrite: CloudflareAccessSignInState?
        h.environment.browser.onStart = { stateAtStart = h.app.accessSignIn }
        h.environment.onWrite = { _ in stateAtWrite = h.app.accessSignIn }
        let session = Fixture.session()

        let signingIn = h.signIn(alias: "Work")
        await h.environment.browser.waitForBrowser()
        #expect(stateAtStart == .checking(target: Fixture.gatewayURL))
        #expect(h.app.accessSignIn == .waitingForBrowser(target: Fixture.gatewayURL, link: Fixture.link, opened: browserOpened,
                                                         host: "gateway.example.com", team: Fixture.team))
        #expect(h.app.isSigningInToAccess)
        #expect(h.environment.made.isEmpty)
        h.environment.browser.finish(session)
        await signingIn.value

        // It stays checking until the session is saved.
        #expect(stateAtWrite == .checking(target: Fixture.gatewayURL))
        #expect(h.app.accessSignIn == .idle)
        #expect(!h.app.isSigningInToAccess)
        #expect(h.app.connectionState == .connected)
        let saved = try #require(h.environment.credentials[Fixture.key(Fixture.gateway)])
        #expect(saved.accessSession == session)
        #expect(saved.access == nil && saved.deviceToken == nil && saved.scopes == nil)
        #expect(h.environment.made.count == 1)
        #expect(h.environment.made.last?.credentials.accessSession == session)
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL])
        #expect(h.app.activeGateway?.label == "Work")
        #expect(h.app.accessIdentity?.email == "person-a@example.com")
        #expect(h.app.notice == "person-a@example.com でサインインしました")
        await h.app.disconnect()
    }

    @Test func withoutAnEmailTheNoticeNamesTheSubject() async throws {
        let h = try SignInHarness()
        await h.signIn(as: Fixture.session(email: nil))
        #expect(h.app.notice == "person-a でサインインしました")
        await h.app.disconnect()
    }

    @Test func cancellingWhileTheBrowserIsOpenSavesNothing() async throws {
        let h = try SignInHarness()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        h.app.cancelCloudflareAccessSignIn()
        #expect(h.app.accessSignIn == .idle)
        h.environment.browser.finish(Fixture.session())
        await signingIn.value
        #expect(h.app.accessSignIn == .idle)
        #expect(h.environment.credentials.isEmpty)
        #expect(h.environment.made.isEmpty)
        #expect(h.app.savedGateways.isEmpty)
    }

    @Test func aSecondSignInWaitsForTheFirstToEnd() async throws {
        let h = try SignInHarness()
        let first = h.signIn()
        await h.environment.browser.waitForBrowser()
        let waiting = h.app.accessSignIn
        await h.app.signInWithCloudflareAccess(urlText: Fixture.other, secret: "", password: false, setupCode: "")
        #expect(h.app.accessSignIn == waiting)
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL])
        h.app.cancelCloudflareAccessSignIn()
        await first.value
    }

    @Test func aSignInCannotStartWhileTheLastOneIsStillConnecting() async throws {
        let h = try SignInHarness()
        let held = SignInGateway(holdConnect: true)
        h.environment.gateways[Fixture.gateway] = [held]
        let session = Fixture.session()
        let first = h.signIn()
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(session)
        // The session is saved, and the sign-in's connect is still under way.
        await held.waitForConnect()
        #expect(h.app.accessSignIn == .idle)
        await h.app.signInWithCloudflareAccess(urlText: Fixture.other, secret: "", password: false, setupCode: "")
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL])
        await held.releaseConnect()
        await first.value
        #expect(h.app.connectionState == .connected)
        #expect(h.app.accessSignIn == .idle)
        #expect(h.app.notice == "person-a@example.com でサインインしました")
        await h.app.disconnect()
    }

    @Test func aMistypedConnectLeavesARunningSignInAlone() async throws {
        let h = try SignInHarness()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        let waiting = h.app.accessSignIn
        await h.app.connect(urlText: "ws://gateway.example.com", secret: "", password: false, setupCode: "")
        #expect(h.app.accessSignIn == waiting)
        h.app.cancelCloudflareAccessSignIn()
        await signingIn.value
    }

    @Test func aSessionForAnotherOriginIsNotSaved() async throws {
        let h = try SignInHarness()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(Fixture.session(origin: "https://other.example.com"))
        await signingIn.value
        #expect(h.app.accessSignIn == .failed(target: Fixture.gatewayURL, message: Fixture.couldNotConnectMessage))
        #expect(h.environment.credentials.isEmpty)
        #expect(h.environment.made.isEmpty)
    }

    @Test func aFailedDiscoveryShowsItsMessageAndSavesNothing() async throws {
        let h = try SignInHarness()
        let failure = GatewayFailure(code: "ACCESS_METADATA_INVALID", message: "Cloudflare Access の応答を検証できなかったため、サインインを中止しました。URL を確認してください。")
        h.environment.browser.discoveryFailure = failure
        await h.signIn().value
        #expect(h.app.accessSignIn == .failed(target: Fixture.gatewayURL, message: failure.message))
        #expect(h.environment.browser.linksShown == 0)
        #expect(h.environment.credentials.isEmpty)
        #expect(h.environment.made.isEmpty)
    }

    @Test func anInvalidURLStopsBeforeTheBrowserOpens() async throws {
        let h = try SignInHarness()
        await h.signIn("ws://gateway.example.com").value
        #expect(h.environment.browser.gateways.isEmpty)
        #expect(h.app.accessSignIn == .idle)
        #expect(h.app.connectionState == .failed("リモート接続には wss:// の安全な Gateway URL を指定してください。"))
    }

    @Test func withoutABrowserSignInTheSignInFailsAndSavesNothing() async throws {
        var credentials: [String: GatewayCredentials] = [:]
        let access = GatewayConnectionAccess(read: { credentials[$0] }, write: { credentials[$1] = $0 }, delete: { credentials[$0] = nil },
                                             makeService: { _, _ in SignInGateway() })
        let app = AppModel(persistenceFactory: { _ in ConversationFile().open() }, profileRepository: TestGatewayProfileRepository(), connectionAccess: access)
        await app.signInWithCloudflareAccess(urlText: Fixture.gateway, secret: "", password: false, setupCode: "")
        guard case .failed(let target, let message) = app.accessSignIn else { Issue.record("Expected a failed sign-in"); return }
        #expect(target == Fixture.gatewayURL)
        #expect(!message.isEmpty)
        #expect(credentials.isEmpty)
    }

    @Test func theLiveSignInOpensNoBrowserBeforeTheApplicationIsVerified() async throws {
        // Nothing listens on loopback port 1, so discovery fails without leaving this Mac.
        let unreachable = try #require(URL(string: "http://127.0.0.1:1"))
        let gateway = try #require(URL(string: "ws://127.0.0.1:1/"))
        let endpoints = try #require(CloudflareAccessEndpoints.loopbackFixture(unreachable))
        var opened: [URL] = []
        var shown = 0
        let live = CloudflareAccessAuthenticator.live(endpoints: endpoints, openBrowser: { opened.append($0); return true })
        await #expect {
            _ = try await live.signIn(gateway) { _, _, _, _ in shown += 1 }
        } throws: { ($0 as? GatewayFailure)?.code == "ACCESS_UNREACHABLE" }
        #expect(opened.isEmpty)
        #expect(shown == 0)
    }

    @Test func aSetupCodeThatExpiresDuringTheBrowserSignInStillConnects() async throws {
        let h = try SignInHarness()
        // Far from the wall clock, so decoding the code again on either clock would refuse it.
        h.environment.clock.now = Date(timeIntervalSince1970: 1_000_000_000)
        let code = Fixture.setupCode(expiresAt: h.environment.clock.now.addingTimeInterval(1))
        h.environment.browser.onStart = { h.environment.clock.now += 600 }
        let session = Fixture.session()
        let signingIn = h.signIn("", setupCode: code)
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(session)
        await signingIn.value
        #expect(h.app.connectionState == .connected)
        #expect(h.app.errorMessage == nil)
        #expect(h.environment.made.last?.credentials.bootstrapToken == "fresh-bootstrap")
        #expect(h.environment.made.last?.credentials.accessSession == session)
        await h.app.disconnect()
    }

    @Test func aSignInThatFinishesDuringAReconnectConnectsOnceTheReconnectIsDone() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        let held = SignInGateway(holdConnect: true)
        h.environment.gateways[Fixture.gateway] = [SignInGateway(), held, SignInGateway()]
        await h.app.restore()
        let reconnecting = Task { await h.app.retryConnection() }
        await held.waitForConnect()
        #expect(h.app.changingConnection)
        let session = Fixture.session()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(session)
        // The sign-in keeps its session and waits for the reconnect to finish.
        try await eventually { h.app.accessSignIn == .checking(target: Fixture.gatewayURL) }
        #expect(h.environment.made.count == 2)
        await held.releaseConnect()
        await reconnecting.value
        await signingIn.value
        #expect(h.app.connectionState == .connected)
        #expect(h.app.accessSignIn == .idle)
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == session)
        #expect(h.environment.made.count == 3)
        #expect(h.environment.made.last?.credentials.accessSession == session)
        await h.app.disconnect()
    }

    @Test func aSignInThatCannotStartItsConnectSaysSoAndSavesNothing() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        let held = SignInGateway(holdConnect: true)
        h.environment.gateways[Fixture.gateway] = [SignInGateway(), held]
        await h.app.restore()
        let reconnecting = Task { await h.app.retryConnection() }
        await held.waitForConnect()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(Fixture.session())
        try await eventually { h.app.accessSignIn == .checking(target: Fixture.gatewayURL) }
        // The reconnect outlasts the ten seconds the sign-in waits for it.
        h.environment.clock.now += 11
        try await eventually { !h.app.isSigningInToAccess }
        #expect(h.app.accessSignIn == .failed(target: Fixture.gatewayURL, message: Fixture.couldNotConnectMessage))
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == nil)
        await held.releaseConnect()
        await reconnecting.value
        await signingIn.value
        #expect(h.environment.made.count == 2)
        await h.app.disconnect()
    }

    @Test func aSignInWhoseConnectCannotStartOnceTheSessionIsSavedSaysSo() async throws {
        let h = try SignInHarness()
        h.environment.serviceFailure = GatewayFailure(code: "DEVICE_IDENTITY_UNAVAILABLE", message: "Synthetic failure")
        let session = Fixture.session()
        await h.signIn(as: session)
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == session)
        #expect(h.app.accessSignIn == .failed(target: Fixture.gatewayURL, message: Fixture.couldNotConnectMessage))
        #expect(h.app.connectionState == .failed("Synthetic failure"))
    }

    /// Once the sign-in's connect has started, the Gateway's answer stands as it would for any connect.
    @Test(arguments: [
        (GatewayFailure(code: "NOT_PAIRED", message: "pairing required", details: .object(["requestId": .string("request-1")])),
         ConnectionState.pairing(requestID: "request-1", message: Fixture.pairingMessage), CloudflareAccessSignInState.idle),
        (GatewayFailure(code: "ACCESS_REQUIRED", message: Fixture.refusedMessage),
         ConnectionState.failed(Fixture.refusedMessage), CloudflareAccessSignInState.required(target: Fixture.gatewayURL, message: Fixture.refusedMessage)),
    ])
    func theFirstConnectOfASignInShowsTheGatewaysAnswer(refusal: GatewayFailure, connection: ConnectionState, signIn: CloudflareAccessSignInState) async throws {
        let h = try SignInHarness()
        h.environment.gateways[Fixture.gateway] = [SignInGateway(failure: refusal)]
        await h.signIn(as: Fixture.session())
        #expect(h.app.connectionState == connection)
        #expect(h.app.accessSignIn == signIn)
    }

    @Test func reconnectsWaitWhileASignInRuns() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        let first = SignInGateway()
        h.environment.gateways[Fixture.gateway] = [first]
        await h.app.restore()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        await h.app.retryConnection()
        #expect(h.environment.made.count == 1)
        #expect(h.app.connectionState == .connected)
        // Nor does a dropped connection schedule the automatic reconnect.
        await first.dropConnection()
        try await eventually { h.app.connectionState == .disconnected }
        #expect(h.app.reconnectTask == nil)
        h.app.cancelCloudflareAccessSignIn()
        await signingIn.value
    }

    @Test func anotherGatewaysRefusalLeavesTheSignInAlone() async throws {
        let h = try SignInHarness(saved: [Fixture.other])
        let refusal = GatewayFailure(code: "ACCESS_REQUIRED", message: "Cloudflare Access のログインを求められました。ブラウザでサインインするか、Access のサービストークン（Client ID と Client Secret）を入力してください。")
        let refusing = SignInGateway(failure: refusal, holdConnect: true)
        h.environment.gateways[Fixture.other] = [SignInGateway(), refusing]
        await h.app.restore()
        let reconnecting = Task { await h.app.retryConnection() }
        await refusing.waitForConnect()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        let waiting = h.app.accessSignIn
        await refusing.releaseConnect()
        await reconnecting.value
        #expect(h.app.connectionState == .failed(refusal.message))
        #expect(h.app.accessSignIn == waiting)
        h.app.cancelCloudflareAccessSignIn()
        await signingIn.value
    }

    @Test func signingInAgainAfterAFailureTargetsTheGatewayThatFailed() async throws {
        let h = try SignInHarness(saved: [Fixture.other])
        await h.app.restore()
        h.environment.browser.discoveryFailure = GatewayFailure(code: "ACCESS_UNREACHABLE", message: "Cloudflare Access に接続できませんでした。ネットワークを確認して、もう一度お試しください。")
        await h.signIn().value
        #expect(h.app.accessSignIn.target == Fixture.gatewayURL)
        await h.app.signInWithCloudflareAccessAgain()
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL, Fixture.gatewayURL])
        await h.app.disconnect()
    }

    @Test func signingInAgainAfterAFailedSignInRepeatsItWithWhatItWasGiven() async throws {
        let h = try SignInHarness()
        h.environment.browser.discoveryFailure = GatewayFailure(code: "ACCESS_UNREACHABLE", message: "Cloudflare Access に接続できませんでした。ネットワークを確認して、もう一度お試しください。")
        await h.signIn("", setupCode: Fixture.setupCode(), alias: "Work").value
        #expect(h.app.accessSignIn.target == Fixture.gatewayURL)
        // Nothing was saved, so only the failed sign-in still has the setup code's bootstrap token and the name.
        #expect(h.environment.credentials.isEmpty)
        h.environment.browser.discoveryFailure = nil
        let session = Fixture.session()
        let signingIn = Task { await h.app.signInWithCloudflareAccessAgain() }
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(session)
        await signingIn.value
        #expect(h.app.connectionState == .connected)
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL, Fixture.gatewayURL])
        #expect(h.environment.made.last?.credentials.bootstrapToken == "fresh-bootstrap")
        #expect(h.environment.made.last?.credentials.accessSession == session)
        #expect(h.app.activeGateway?.label == "Work")
        await h.app.disconnect()
    }

    @Test func signingInAgainOnceTheSetupCodeHasExpiredAsksForANewCode() async throws {
        let h = try SignInHarness()
        h.environment.browser.discoveryFailure = GatewayFailure(code: "ACCESS_UNREACHABLE", message: "Cloudflare Access に接続できませんでした。ネットワークを確認して、もう一度お試しください。")
        await h.signIn("", setupCode: Fixture.setupCode(expiresAt: h.environment.clock.now.addingTimeInterval(60))).value
        #expect(h.app.accessSignIn.target == Fixture.gatewayURL)
        // The code's bootstrap token is good only until the code expires, so the browser stays closed.
        h.environment.clock.now += 61
        await h.app.signInWithCloudflareAccessAgain()
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL])
        #expect(h.app.accessSignIn == .failed(target: Fixture.gatewayURL, message: "セットアップコードの有効期限が切れています。新しいコードを発行してください。"))
    }

    @Test func whatAFailedSignInWasGivenIsForgottenOnceItsFailureIsGone() async throws {
        let h = try SignInHarness(saved: [Fixture.other])
        h.environment.browser.discoveryFailure = GatewayFailure(code: "ACCESS_UNREACHABLE", message: "Cloudflare Access に接続できませんでした。ネットワークを確認して、もう一度お試しください。")
        await h.signIn().value
        #expect(h.app.accessSignIn.target == Fixture.gatewayURL)
        // Another Gateway's refusal replaces the failure, so signing in again is for that Gateway.
        h.environment.gateways[Fixture.other] = [SignInGateway(failure: GatewayFailure(code: "ACCESS_REQUIRED", message: Fixture.refusedMessage))]
        await h.app.restore()
        #expect(h.app.accessSignIn == .required(target: Fixture.otherURL, message: Fixture.refusedMessage))
        h.environment.browser.discoveryFailure = nil
        let signingIn = Task { await h.app.signInWithCloudflareAccessAgain() }
        await h.environment.browser.waitForBrowser()
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL, Fixture.otherURL])
        h.app.cancelCloudflareAccessSignIn()
        await signingIn.value
    }

    /// The form repeats a failed sign-in only until the form changes after it. An edit while the sign-in runs
    /// comes before the failure, which stays to be repeated. An edit after it lets go of the failure, so that the
    /// form's own inputs sign in next, such as a URL corrected after the mistyped one named no Access application.
    @Test func aFailedSignInIsRepeatedOnlyUntilTheFormChangesAfterIt() async throws {
        let h = try SignInHarness()
        let notProtected = GatewayFailure(code: "ACCESS_NOT_PROTECTED", message: "この URL では Cloudflare Access のアプリを確認できませんでした。URL と、Gateway が Cloudflare Access で保護されているかを確認してください。")
        h.environment.browser.discoveryFailure = notProtected
        // Each sign-in sees the form change while it runs.
        var editedWhileRunning: CloudflareAccessSignInState?
        h.environment.browser.onStart = { h.app.dismissFailedCloudflareAccessSignIn(); editedWhileRunning = h.app.accessSignIn }
        await h.signIn(Fixture.other).value
        #expect(editedWhileRunning == .checking(target: Fixture.otherURL))
        let failed = CloudflareAccessSignInState.failed(target: Fixture.otherURL, message: notProtected.message)
        #expect(h.app.accessSignIn == failed)
        await h.app.signInWithCloudflareAccessAgain()
        #expect(h.app.accessSignIn == failed)
        #expect(h.environment.browser.gateways == [Fixture.otherURL, Fixture.otherURL])
        // The form changes after the failure: nothing is left to repeat.
        h.app.dismissFailedCloudflareAccessSignIn()
        #expect(h.app.accessSignIn == .idle)
        await h.app.signInWithCloudflareAccessAgain()
        #expect(h.environment.browser.gateways == [Fixture.otherURL, Fixture.otherURL])
        // A sign-in that a Gateway asked for stays asked for.
        h.environment.gateways[Fixture.gateway] = [SignInGateway(failure: GatewayFailure(code: "ACCESS_REQUIRED", message: Fixture.refusedMessage))]
        await h.app.connect(urlText: Fixture.gateway, secret: "", password: false, setupCode: "")
        h.app.dismissFailedCloudflareAccessSignIn()
        #expect(h.app.accessSignIn == .required(target: Fixture.gatewayURL, message: Fixture.refusedMessage))
    }

    @Test func signingInAgainAfterARefusedSetupCodePairsWithItsBootstrapToken() async throws {
        let h = try SignInHarness()
        let refusal = GatewayFailure(code: "ACCESS_REQUIRED", message: "Cloudflare Access のログインを求められました。ブラウザでサインインするか、Access のサービストークン（Client ID と Client Secret）を入力してください。")
        h.environment.gateways[Fixture.gateway] = [SignInGateway(failure: refusal), SignInGateway()]
        await h.app.connect(urlText: "", secret: "", password: false, setupCode: Fixture.setupCode())
        #expect(h.app.accessSignIn == .required(target: Fixture.gatewayURL, message: refusal.message))
        // The form lets go of a setup code once it is sent, so the sign-in goes by the Gateway that asked.
        let session = Fixture.session()
        let signingIn = Task { await h.app.signInWithCloudflareAccessAgain() }
        await h.environment.browser.waitForBrowser()
        h.environment.browser.finish(session)
        await signingIn.value
        #expect(h.app.connectionState == .connected)
        #expect(h.environment.browser.gateways == [Fixture.gatewayURL])
        #expect(h.environment.made.last?.credentials.bootstrapToken == "fresh-bootstrap")
        #expect(h.environment.made.last?.credentials.accessSession == session)
        await h.app.disconnect()
    }

    @Test(arguments: [false, true])
    func deletingTheGatewayASignInIsForCancelsIt(targetIsActive: Bool) async throws {
        let h = try SignInHarness(saved: targetIsActive ? [Fixture.other, Fixture.gateway] : [Fixture.gateway, Fixture.other])
        await h.app.restore()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        let target = try #require(h.app.savedGateways.first { $0.endpoint == Fixture.gateway })
        #expect(await h.app.deleteGateway(target))
        #expect(h.app.accessSignIn == .idle)
        h.environment.browser.finish(Fixture.session())
        await signingIn.value
        #expect(h.app.savedGateways.map(\.endpoint) == [Fixture.other])
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)] == nil)
        #expect(h.environment.made.allSatisfy { $0.credentials.accessSession == nil })
    }

    enum Interruption: CaseIterable, Sendable { case connect, switchGateway, demo, disconnect }

    @Test(arguments: Interruption.allCases)
    func anotherConnectionChangeCancelsTheSignIn(_ interruption: Interruption) async throws {
        let h = try SignInHarness(saved: [Fixture.other])
        await h.app.restore()
        let signingIn = h.signIn()
        await h.environment.browser.waitForBrowser()
        switch interruption {
        case .connect: await h.app.connect(urlText: Fixture.other, secret: "typed-token", password: false, setupCode: "")
        case .switchGateway: await h.app.switchGateway(try #require(h.app.savedGateways.first))
        case .demo: await h.app.startDemo()
        case .disconnect: await h.app.disconnect()
        }
        #expect(h.app.accessSignIn == .idle)
        h.environment.browser.finish(Fixture.session())
        await signingIn.value
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)] == nil)
        #expect(!h.app.savedGateways.contains { $0.endpoint == Fixture.gateway })
        await h.app.disconnect()
    }
}

// MARK: - The saved session

// The limit cancels a test left waiting on a fixture that never answers.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AccessSessionConnectionTests {
    @Test(arguments: [
        GatewayFailure(code: "ACCESS_REQUIRED", message: "Cloudflare Access のサインインが無効になりました。ブラウザでもう一度サインインしてください。"),
        GatewayFailure(code: "ACCESS_IDENTITY_REQUIRED", message: "この Gateway を操作するには Cloudflare Access のサインインが必要です。ブラウザで本人のアカウントにサインインしてください。"),
    ])
    func aRefusalThatNeedsASignInAsksForOneWithoutOpeningTheBrowser(failure: GatewayFailure) async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: Fixture.session())
        h.environment.gateways[Fixture.gateway] = [SignInGateway(failure: failure)]
        await h.app.restore()
        #expect(h.app.accessSignIn == .required(target: Fixture.gatewayURL, message: failure.message))
        #expect(h.app.connectionState == .failed(failure.message))
        // Settings no longer shows the refused session as signed in.
        #expect(h.app.accessIdentity == nil)
        #expect(h.environment.made.count == 1)
        #expect(h.environment.browser.gateways.isEmpty)
    }

    @Test func theNextConnectionChangeClearsASignInRequestForTheGatewayBefore() async throws {
        let h = try SignInHarness(saved: [Fixture.other, Fixture.gateway])
        h.environment.gateways[Fixture.gateway] = [SignInGateway(failure: GatewayFailure(code: "ACCESS_REQUIRED", message: "Cloudflare Access のログインを求められました。"))]
        h.environment.gateways[Fixture.other] = [SignInGateway(failure: GatewayFailure(code: "AUTH_FAILED", message: "Synthetic failure"))]
        await h.app.restore()
        #expect(h.app.accessSignIn.target == Fixture.gatewayURL)
        await h.app.switchGateway(try #require(h.app.savedGateways.first { $0.endpoint == Fixture.other }))
        #expect(h.app.connectionState == .failed("Synthetic failure"))
        #expect(h.app.accessSignIn == .idle)
    }

    @Test(arguments: [
        (GatewayFailure(code: "NOT_PAIRED", message: "operator role policies require a verified user identity",
                        details: .object(["code": .string("AUTH_VERIFIED_USER_REQUIRED")])), nil as String?),
        (GatewayFailure(code: "NOT_PAIRED", message: "pairing required", details: .object(["requestId": .string("request-1")])), "request-1"),
        (GatewayFailure(code: "NOT_PAIRED", message: "pairing required", details: .object(["code": .string("PAIRING_REQUIRED")])), ""),
    ])
    func onlyARefusalThatNamesAPairingIsShownAsOne(failure: GatewayFailure, requestID: String?) async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: Fixture.session())
        h.environment.gateways[Fixture.gateway] = [SignInGateway(failure: failure)]
        await h.app.restore()
        if let requestID {
            #expect(h.app.connectionState == .pairing(requestID: requestID, message: "Gateway 側でこの端末を承認してから、再接続してください。"))
        } else {
            #expect(h.app.connectionState == .failed(failure.message))
        }
    }

    @Test func reenteringTheGatewayTokenKeepsTheSession() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        let session = Fixture.session()
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: session)
        await h.app.connect(urlText: Fixture.gateway, secret: "rotated-token", password: false, setupCode: "")
        #expect(h.environment.made.last?.credentials.token == "rotated-token")
        #expect(h.environment.made.last?.credentials.accessSession == session)
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == session)
        await h.app.disconnect()
    }

    @Test func pairingAgainWithASetupCodeKeepsTheSession() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        let session = Fixture.session()
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: session)
        await h.app.connect(urlText: "", secret: "", password: false, setupCode: Fixture.setupCode())
        #expect(h.environment.made.last?.credentials.bootstrapToken == "fresh-bootstrap")
        #expect(h.environment.made.last?.credentials.accessSession == session)
        await h.app.disconnect()
    }

    @Test func theHelloDeviceTokenIsNotSavedBesideASession() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        let session = Fixture.session()
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: session)
        h.environment.gateways[Fixture.gateway] = [SignInGateway(issuedDeviceToken: "issued-device-token")]
        await h.app.restore()
        #expect(h.app.connectionState == .connected)
        let saved = try #require(h.environment.credentials[Fixture.key(Fixture.gateway)])
        #expect(saved.accessSession == session)
        #expect(saved.deviceToken == nil)
        await h.app.disconnect()
    }

    @Test func enteringAServiceTokenReplacesTheSession() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: Fixture.session())
        await h.app.connect(urlText: Fixture.gateway, secret: "", password: false, setupCode: "", access: Fixture.serviceToken)
        let saved = try #require(h.environment.credentials[Fixture.key(Fixture.gateway)])
        #expect(saved.access == Fixture.serviceToken)
        #expect(saved.accessSession == nil)
        #expect(h.app.accessIdentity == nil)
        await h.app.disconnect()
    }

    @Test func signingInAsSomeoneElseForgetsWhatThisMacCachedForTheGateway() async throws {
        let file = ConversationFile(personACache())
        let h = try SignInHarness(saved: [Fixture.gateway], files: [Fixture.gateway: file])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: Fixture.session(subject: "person-a"))
        await h.app.restore()
        #expect(h.app.draftText == "A's draft")
        var cachedWhenSaved: ConversationStore?
        h.environment.onWrite = { _ in cachedWhenSaved = file.state }
        let personB = Fixture.session(subject: "person-b", email: "person-b@example.com")
        await h.signIn(as: personB)
        // The cache was gone from disk before person B's session was saved.
        let wiped = try #require(cachedWhenSaved)
        #expect(wiped.drafts.isEmpty && wiped.transcripts.isEmpty && wiped.pending.isEmpty && wiped.viewerProfileID == nil)
        #expect(h.app.connectionState == .connected)
        #expect(h.app.draftText.isEmpty)
        #expect(h.app.timelineViewer == .unresolved)
        #expect(file.state.pending.isEmpty && file.state.viewerProfileID == nil)
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == personB)
        await h.app.disconnect()
    }

    @Test func aServiceTokenInBetweenDoesNotHandTheCacheToTheNextPersonWhoSignsIn() async throws {
        let file = ConversationFile(personACache())
        let h = try SignInHarness(saved: [Fixture.gateway], files: [Fixture.gateway: file])
        await h.signIn(as: Fixture.session(subject: "person-a"))
        #expect(h.app.draftText == "A's draft")
        // A service token takes the place of person A's session; the cache is still theirs.
        await h.app.connect(urlText: Fixture.gateway, secret: "", password: false, setupCode: "", access: Fixture.serviceToken)
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == nil)
        #expect(h.app.draftText == "A's draft")
        var cachedWhenSaved: ConversationStore?
        h.environment.onWrite = { _ in cachedWhenSaved = file.state }
        let personB = Fixture.session(subject: "person-b", email: "person-b@example.com")
        await h.signIn(as: personB)
        let wiped = try #require(cachedWhenSaved)
        #expect(wiped.drafts.isEmpty && wiped.transcripts.isEmpty && wiped.pending.isEmpty && wiped.viewerProfileID == nil)
        #expect(h.app.connectionState == .connected)
        #expect(h.app.draftText.isEmpty)
        #expect(h.app.timelineViewer == .unresolved)
        #expect(file.state.accessOwner == personB.account)
        await h.app.disconnect()
    }

    @Test func aSignInWhoseSessionCannotBeSavedLeavesTheActiveGatewaysConversationsInPlace() async throws {
        let personA = Fixture.session(subject: "person-a").account
        var cache = personACache(); cache.accessOwner = personA
        let gatewayFile = ConversationFile(cache), otherFile = ConversationFile(otherGatewayCache())
        let h = try SignInHarness(saved: [Fixture.gateway, Fixture.other], files: [Fixture.gateway: gatewayFile, Fixture.other: otherFile])
        await h.app.restore()
        #expect(h.app.endpoint == Fixture.otherURL)
        h.environment.onWrite = { _ in throw GatewayFailure(code: "KEYCHAIN_UNAVAILABLE", message: "Synthetic Keychain failure") }
        await h.signIn(as: Fixture.session(subject: "person-b", email: "person-b@example.com"))
        #expect(h.app.accessSignIn == .failed(target: Fixture.gatewayURL, message: Fixture.couldNotConnectMessage))
        // Person A's cache is gone but still theirs, and the active Gateway still shows its own conversations.
        #expect(gatewayFile.state.drafts.isEmpty && gatewayFile.state.transcripts.isEmpty && gatewayFile.state.pending.isEmpty)
        #expect(gatewayFile.state.accessOwner == personA)
        #expect(h.app.endpoint == Fixture.otherURL)
        #expect(h.app.draftText == "Other's draft")
        // Reconnecting to it saves its conversations where they belong.
        h.environment.onWrite = nil
        await h.app.retryConnection()
        #expect(h.app.connectionState == .connected)
        #expect(gatewayFile.state.sessions.isEmpty)
        #expect(otherFile.state.selectedDraft.text == "Other's draft")
        await h.app.disconnect()
    }

    /// A sign-in cancelled once person B's session is saved leaves the cache to person A. 再接続 with that
    /// session hands the cache to person B first, so that what B leaves is not kept for A's next sign-in.
    @Test func reconnectingWithTheSessionOfACancelledSignInHandsTheCacheToItsPerson() async throws {
        let personA = Fixture.session(subject: "person-a")
        var cache = personACache(); cache.accessOwner = personA.account
        let file = ConversationFile(cache)
        let h = try SignInHarness(saved: [Fixture.gateway], files: [Fixture.gateway: file])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: personA)
        await h.app.restore()
        let personB = Fixture.session(subject: "person-b", email: "person-b@example.com")
        // キャンセル lands as person B's session is saved, before the sign-in's connect hands them the cache.
        let app = h.app
        h.environment.onWrite = { saved in if saved.accessSession == personB { app.cancelCloudflareAccessSignIn() } }
        await h.signIn(as: personB)
        h.environment.onWrite = nil
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)]?.accessSession == personB)
        #expect(file.state.accessOwner == personA.account)
        await h.app.retryConnection()
        #expect(h.app.connectionState == .connected)
        #expect(file.state.accessOwner == personB.account)
        h.app.draftText = "B's draft"
        await h.app.disconnect()
        await h.signIn(as: personA)
        #expect(h.app.connectionState == .connected)
        #expect(h.app.draftText.isEmpty)
        await h.app.disconnect()
    }

    /// However a session came to be saved, a reconnect with it never starts with conversations that someone
    /// else owns: they are forgotten first.
    @Test func reconnectingWithSomeoneElsesSessionForgetsTheConversationsFirst() async throws {
        let personA = Fixture.session(subject: "person-a")
        var cache = personACache(); cache.accessOwner = personA.account
        let file = ConversationFile(cache)
        let h = try SignInHarness(saved: [Fixture.gateway], files: [Fixture.gateway: file])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: personA)
        await h.app.restore()
        #expect(h.app.draftText == "A's draft")
        await h.app.disconnect()
        let personB = Fixture.session(subject: "person-b", email: "person-b@example.com")
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: personB)
        await h.app.retryConnection()
        #expect(h.app.connectionState == .connected)
        #expect(h.app.draftText.isEmpty)
        #expect(file.state.pending.isEmpty && file.state.viewerProfileID == nil)
        #expect(file.state.accessOwner == personB.account)
        await h.app.disconnect()
    }

    @Test func signingInAgainAsTheSamePersonKeepsTheCache() async throws {
        let file = ConversationFile(personACache())
        let h = try SignInHarness(saved: [Fixture.gateway], files: [Fixture.gateway: file])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: Fixture.session(subject: "person-a"))
        await h.app.restore()
        await h.signIn(as: Fixture.session(subject: "person-a", expiresAt: Date(timeIntervalSince1970: 1_950_000_000)))
        #expect(h.app.draftText == "A's draft")
        #expect(file.state.viewerProfileID == "profile-a")
        await h.app.disconnect()
    }

    @Test func theConnectionEndsOnceWhenItsSignInExpires() async throws {
        let h = try SignInHarness()
        let clock = h.environment.clock
        let gateway = SignInGateway()
        h.environment.gateways[Fixture.gateway] = [gateway]
        await h.signIn(as: Fixture.session(expiresAt: clock.now.addingTimeInterval(3600)))
        #expect(h.app.connectionState == .connected)
        let expiry = try #require(h.app.accessExpiryTask)
        await clock.waitForSleep()
        #expect(clock.sleeps == [.seconds(3600)])
        clock.fire()
        await expiry.value
        #expect(h.app.accessSignIn == .required(target: Fixture.gatewayURL, message: Fixture.expiredMessage))
        #expect(h.app.connectionState == .failed(Fixture.expiredMessage))
        // Settings no longer shows the expired session as signed in.
        #expect(h.app.accessIdentity == nil)
        #expect(await gateway.disconnectCount == 1)
        #expect(clock.sleeps.count == 1)
        #expect(h.environment.made.count == 1)
    }

    @Test func anExpiryOutlivedByItsConnectionDoesNothing() async throws {
        let h = try SignInHarness()
        let clock = h.environment.clock
        await h.signIn(as: Fixture.session(expiresAt: clock.now.addingTimeInterval(3600)))
        let expiry = try #require(h.app.accessExpiryTask)
        await clock.waitForSleep()
        await h.app.disconnect()
        #expect(h.app.accessExpiryTask == nil)
        clock.fire()
        await expiry.value
        #expect(h.app.accessSignIn == .idle)
        #expect(h.app.connectionState == .disconnected)
    }

    @Test func theDemoAndDeletingTheGatewayForgetWhoIsSignedIn() async throws {
        let h = try SignInHarness(saved: [Fixture.gateway])
        h.environment.credentials[Fixture.key(Fixture.gateway)] = GatewayCredentials(accessSession: Fixture.session())
        await h.app.restore()
        #expect(h.app.accessIdentity?.subject == "person-a")
        #expect(h.app.accessIdentity?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        await h.app.startDemo()
        #expect(h.app.accessIdentity == nil)
        await h.app.switchGateway(try #require(h.app.savedGateways.first))
        #expect(h.app.accessIdentity?.subject == "person-a")
        #expect(await h.app.deleteGateway(try #require(h.app.activeGateway)))
        #expect(h.app.accessIdentity == nil)
        #expect(h.environment.credentials[Fixture.key(Fixture.gateway)] == nil)
    }
}
