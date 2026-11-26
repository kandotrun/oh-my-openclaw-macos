import CryptoKit
import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

@MainActor final class TestGatewayProfileRepository: GatewayProfilePersisting {
    var state: GatewayProfiles
    init(_ state: GatewayProfiles = GatewayProfiles()) { self.state = state }
    func load() throws -> GatewayProfiles { state }
    func save(_ profiles: GatewayProfiles) throws { state = profiles }
}

private func gatewayHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func profileFile(_ suite: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
}

private let sharedSession = ChatSession(key: "agent:shared:main", agentID: "shared", sessionID: "same-physical-id", title: "Main", isMain: true)
private func gatewayStore(_ text: String) -> ConversationStore {
    var store = ConversationStore(); store.upsertSession(sharedSession); store.selectedID = sharedSession.id
    store.setDraft(ComposerDraft(text: text), for: sharedSession.id)
    store.transcripts[sharedSession.id] = [ChatMessage(id: "same-message-id", role: .assistant, text: text + " history")]
    return store
}

private actor GatewayMemoryDisk: ConversationPersisting {
    var state: ConversationStore
    private var holdLoad = false
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private let loadStarted = AsyncStream<Void>.makeStream()
    var writes: [ConversationStore] = []
    init(_ state: ConversationStore = ConversationStore()) { self.state = state }
    func load() async throws -> ConversationStore {
        if holdLoad { await withCheckedContinuation { loadWaiter = $0; loadStarted.continuation.yield(()) } }
        return state
    }
    func save(_ state: ConversationStore, revision: Int) async throws { self.state = state; writes.append(state) }
    func pauseLoad() { holdLoad = true }
    func waitForLoad() async { for await _ in loadStarted.stream { return } }
    func releaseLoad() { holdLoad = false; loadWaiter?.resume(); loadWaiter = nil }
}

private actor SavedGatewayService: GatewayServing {
    let name: String
    let failure: GatewayFailure?
    let issuedToken: String?
    private var continuation: AsyncStream<GatewayEvent>.Continuation?
    private var holdConnection = false
    private var connectionWaiter: CheckedContinuation<Void, Never>?
    private let connectStarted = AsyncStream<Void>.makeStream()
    private var holdIdentity = false
    private var identityWaiter: CheckedContinuation<Void, Never>?
    private let identityStarted = AsyncStream<Void>.makeStream()
    var disconnectCount = 0
    var connectCount = 0
    init(_ name: String, failure: GatewayFailure? = nil, issuedToken: String? = nil) {
        self.name = name; self.failure = failure; self.issuedToken = issuedToken
    }
    func events() async -> AsyncStream<GatewayEvent> {
        let stream = AsyncStream<GatewayEvent>.makeStream(); continuation = stream.continuation; return stream.stream
    }
    func connect() async throws -> GatewayHello {
        connectCount += 1
        if holdConnection { await withCheckedContinuation { connectionWaiter = $0; connectStarted.continuation.yield(()) } }
        if let failure { throw failure }
        var payload: [String: JSONValue] = ["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("shared"), "mainSessionKey": .string(sharedSession.key),
        ])])]
        if let issuedToken { payload["auth"] = .object(["deviceToken": .string(issuedToken)]) }
        return GatewayHello(payload: .object(payload))
    }
    func disconnect() async { disconnectCount += 1; continuation?.finish() }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "chat.history":
            return .object(["sessionId": .string("same-physical-id"), "messages": .array([
                .object(["id": .string("same-message-id"), "role": .string("assistant"), "content": .string(name + " history")]),
            ])])
        case "agent.identity.get":
            if holdIdentity { await withCheckedContinuation { identityWaiter = $0; identityStarted.continuation.yield(()) } }
            return .object(["agentId": .string("shared"), "name": .string(name)])
        default: return .object([:])
        }
    }
    func pauseConnect() { holdConnection = true }
    func waitForConnect() async { for await _ in connectStarted.stream { return } }
    func releaseConnect() { holdConnection = false; connectionWaiter?.resume(); connectionWaiter = nil }
    func pauseIdentity() { holdIdentity = true }
    func waitForIdentity() async { for await _ in identityStarted.stream { return } }
    func releaseIdentity() { holdIdentity = false; identityWaiter?.resume(); identityWaiter = nil }
}

@MainActor private final class SavedConnectionFixture {
    var credentials: [String: GatewayCredentials] = [:]
    var deleteError: GatewayFailure?
    var reads: [String] = []
    var made: [(String, GatewayCredentials)] = []
    var services: [String: SavedGatewayService] = [:]
    var access: GatewayConnectionAccess {
        GatewayConnectionAccess(read: { self.reads.append($0); return self.credentials[$0] },
                                write: { self.credentials[$1] = $0 },
                                delete: { key in
                                    if let error = self.deleteError { throw error }
                                    self.credentials.removeValue(forKey: key)
                                },
                                makeService: { url, credentials in
                                    self.made.append((url.absoluteString, credentials))
                                    return try #require(self.services[url.absoluteString])
                                })
    }
}

@MainActor private struct SavedGatewayHarness {
    let a = URL(string: "wss://alpha.example/prefix/")!
    let b = URL(string: "wss://beta.example/prefix/")!
    let diskA = GatewayMemoryDisk(gatewayStore("A draft"))
    let diskB = GatewayMemoryDisk(gatewayStore("B draft"))
    let repository: TestGatewayProfileRepository
    let connections = SavedConnectionFixture()
    let app: AppModel
    init(bFailure: GatewayFailure? = nil) throws {
        var profiles = GatewayProfiles(); try profiles.activate(b); try profiles.activate(a, alias: "Alpha")
        repository = TestGatewayProfileRepository(profiles)
        connections.services[a.absoluteString] = SavedGatewayService("Agent A")
        connections.services[b.absoluteString] = SavedGatewayService("Agent B", failure: bFailure)
        connections.credentials["gateway:" + gatewayHash(a.absoluteString)] = GatewayCredentials(deviceToken: "synthetic-a")
        connections.credentials["gateway:" + gatewayHash(b.absoluteString)] = GatewayCredentials(password: "synthetic-b")
        let disks = [gatewayHash(a.absoluteString): diskA, gatewayHash(b.absoluteString): diskB]
        app = AppModel(persistenceFactory: { try #require(disks[$0]) }, profileRepository: repository, connectionAccess: connections.access)
    }
    var profileA: SavedGateway { repository.state.profiles.first { $0.endpoint == a.absoluteString }! }
    var profileB: SavedGateway { repository.state.profiles.first { $0.endpoint == b.absoluteString }! }
}

@MainActor @Suite struct SavedGatewayMetadataTests {
    @Test func legacyMigrationPreservesExactEndpointAndLeavesLegacyValuesAlone() throws {
        let suite = "SavedGatewayTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exact = "wss://Legacy.Example:443/deployment%2Fpath"
        defaults.set(exact, forKey: "lastGateway")
        let file = profileFile(suite)
        defer { try? FileManager.default.removeItem(at: file) }
        let repository = LocalGatewayProfileRepository(defaults: defaults, file: file)
        let profiles = try repository.load()
        #expect(profiles.profiles.count == 1)
        #expect(profiles.lastActiveEndpoint == exact)
        #expect(try profiles.profiles[0].url.absoluteString == exact)
        #expect(defaults.string(forKey: "lastGateway") == exact)
        #expect(try repository.load() == profiles)
    }

    @Test func invalidLegacyEndpointsAreNotSaved() throws {
        let suite = "SavedGatewayTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://gateway.example/?token=synthetic", forKey: "lastGateway")
        let file = profileFile(suite)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try LocalGatewayProfileRepository(defaults: defaults, file: file).load().profiles.isEmpty)
    }

    @Test func profileRemovalIsReadableFromDiskOverExistingPreferences() throws {
        let suite = "SavedGatewayTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let file = profileFile(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let url = try #require(URL(string: "wss://gateway.example/"))
        var original = GatewayProfiles()
        try original.activate(url, alias: "Existing Gateway")
        defaults.set(try JSONEncoder().encode(original), forKey: "savedGateways")
        let repository = LocalGatewayProfileRepository(defaults: defaults, file: file)
        var staged = try repository.load()
        #expect(staged == original)

        staged.remove(endpoint: url.absoluteString)
        try repository.save(staged)

        let reopened = try LocalGatewayProfileRepository(defaults: defaults, file: file).load()
        #expect(reopened.profiles.isEmpty)
        #expect(reopened.lastActiveEndpoint == nil)
        #expect(reopened.pendingCredentialRemoval == url.absoluteString)
    }

    @Test func aliasesSurviveReconnectAndExplicitBlankRenameRestoresHostname() throws {
        let url = URL(string: "wss://gateway.example/prefix/")!
        var profiles = GatewayProfiles()
        try profiles.activate(url)
        #expect(profiles.profiles[0].label == "gateway.example")
        try profiles.activate(url, alias: "  仕事  ")
        try profiles.activate(url)
        try profiles.activate(url, alias: " \n ")
        #expect(profiles.profiles.count == 1)
        #expect(profiles.profiles[0].label == "仕事")
        profiles.rename(endpoint: url.absoluteString, alias: "\n ")
        #expect(profiles.profiles[0].label == "gateway.example")
    }

    @Test func serializedProfilesContainOnlyDisplayMetadata() throws {
        var profiles = GatewayProfiles()
        try profiles.activate(URL(string: "wss://gateway.example/")!, alias: "Work")
        let data = try JSONEncoder().encode(profiles)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["profiles", "lastActiveEndpoint", "useDemo"])
        let rows = try #require(json["profiles"] as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["endpoint", "alias"])
        #expect(try JSONDecoder().decode(GatewayProfiles.self, from: data) == profiles)
        for secretKey in ["password", "token", "bootstrapToken", "deviceToken"] {
            #expect(!String(decoding: data, as: UTF8.self).contains(secretKey))
        }
    }
}

@MainActor @Suite struct SavedGatewayConnectionTests {
    @Test func deletingAnInactiveGatewayKeepsTheActiveConnectionAndDraft() async throws {
        let h = try SavedGatewayHarness()
        let activeProfile = h.profileA
        let inactiveProfile = h.profileB
        let active = try #require(h.connections.services[h.a.absoluteString])
        await h.app.restore()
        h.app.draftText = "A edited before deletion"

        #expect(await h.app.deleteGateway(inactiveProfile))
        #expect(h.app.savedGateways == [activeProfile])
        #expect(h.repository.state.profiles == [activeProfile])
        #expect(h.repository.state.lastActiveEndpoint == h.a.absoluteString)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.b.absoluteString)] == nil)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.a.absoluteString)]?.deviceToken == "synthetic-a")
        #expect(h.app.connectionState == .connected)
        #expect(h.app.activeGateway == activeProfile)
        #expect(h.app.draftText == "A edited before deletion")
        #expect(await active.disconnectCount == 0)
        await h.app.disconnect()
    }

    @Test(arguments: [false, true])
    func deletingTheActiveGatewayFlushesItsDraftAndClearsTheConnection(hasRemainingGateway: Bool) async throws {
        let h = try SavedGatewayHarness()
        let profile = h.profileA
        let remaining = hasRemainingGateway ? [h.profileB] : []
        if !hasRemainingGateway {
            var profiles = GatewayProfiles()
            try profiles.activate(h.a, alias: "Alpha")
            h.repository.state = profiles
        }
        let active = try #require(h.connections.services[h.a.absoluteString])
        await h.app.restore()
        h.app.draftText = "A edited before deletion"
        h.app.errorMessage = "Previous connection error"

        #expect(await h.app.deleteGateway(profile))
        #expect(await active.disconnectCount == 1)
        #expect(await h.diskA.state.selectedDraft.text == "A edited before deletion")
        #expect(h.app.connectionState == .disconnected)
        #expect(h.app.errorMessage == nil)
        #expect(h.app.endpoint == nil)
        #expect(h.app.activeGateway == nil)
        #expect(h.app.sessions.isEmpty)
        #expect(h.app.savedGateways == remaining)
        #expect(h.repository.state.profiles == remaining)
        #expect(h.repository.state.lastActiveEndpoint == nil)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.a.absoluteString)] == nil)
        if hasRemainingGateway {
            #expect(h.connections.credentials["gateway:" + gatewayHash(h.b.absoluteString)]?.password == "synthetic-b")
        }
        await h.app.foreground()
        await h.app.restore()
        #expect(h.connections.made.count == 1)
        #expect(h.app.endpoint == nil)
    }

    @Test func restoreFinishesAnInterruptedCredentialRemoval() async throws {
        let h = try SavedGatewayHarness()
        var profiles = h.repository.state
        profiles.remove(endpoint: h.a.absoluteString)
        h.repository.state = profiles

        await h.app.restore()

        #expect(h.app.savedGateways == [h.profileB])
        #expect(h.repository.state.pendingCredentialRemoval == nil)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.a.absoluteString)] == nil)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.b.absoluteString)]?.password == "synthetic-b")
        #expect(h.connections.made.isEmpty)
    }

    @Test func failingToRemoveCredentialsKeepsTheActiveGateway() async throws {
        let h = try SavedGatewayHarness()
        let profile = h.profileA
        let active = try #require(h.connections.services[h.a.absoluteString])
        await h.app.restore()
        let previous = h.repository.state
        h.connections.deleteError = GatewayFailure(code: "KEYCHAIN_ERROR", message: "Synthetic failure")

        #expect(await h.app.deleteGateway(profile) == false)
        #expect(h.repository.state == previous)
        #expect(h.app.savedGateways == previous.profiles)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.a.absoluteString)]?.deviceToken == "synthetic-a")
        #expect(h.app.connectionState == .connected)
        #expect(h.app.activeGateway == profile)
        #expect(await active.disconnectCount == 0)
        await h.app.disconnect()
    }

    @Test func restoreAndSwitchReuseExactCredentialKeysAndIsolateIdenticalSessionIDs() async throws {
        let h = try SavedGatewayHarness()
        await h.app.restore()
        #expect(h.app.activeGateway?.endpoint == h.a.absoluteString)
        #expect(h.connections.made.last?.1 == GatewayCredentials(deviceToken: "synthetic-a"))
        #expect(h.app.agentName == "Agent A")
        let contextA = h.app.composerContextID
        h.app.draftText = "日本語の書きかけ A"
        await h.app.switchGateway(h.profileB)
        #expect(h.app.activeGateway?.endpoint == h.b.absoluteString)
        #expect(h.app.draftText == "B draft")
        #expect(h.app.messages.map(\.text) == ["Agent B history"])
        #expect(h.app.agentName == "Agent B")
        #expect(h.app.composerContextID != contextA)
        #expect(h.connections.made.last?.1 == GatewayCredentials(password: "synthetic-b"))
        #expect(await h.connections.services[h.a.absoluteString]?.disconnectCount == 1)
        h.app.draftText = "B edited"
        await h.app.switchGateway(h.profileA)
        #expect(h.app.draftText == "日本語の書きかけ A")
        #expect(h.app.messages.map(\.text) == ["Agent A history"])
        #expect(h.app.activeGateway?.label == "Alpha")
        #expect(await h.diskB.state.selectedDraft.text == "B edited")
        #expect(h.connections.reads.contains("gateway:" + gatewayHash(h.a.absoluteString)))
        #expect(h.repository.state.lastActiveEndpoint == h.a.absoluteString)
        await h.app.disconnect()
    }

    @Test(arguments: ["AUTH_FAILED", "NOT_PAIRED"])
    func failedOrPairingAddRetainsBothTargetsAndCanReturnToPreviousProfile(code: String) async throws {
        let failure = GatewayFailure(code: code, message: "Synthetic failure", details: .object(["requestId": .string("synthetic-request")]))
        let h = try SavedGatewayHarness(bFailure: failure)
        var onlyA = GatewayProfiles(); try onlyA.activate(h.a, alias: "Alpha")
        h.repository.state = onlyA
        await h.app.restore()
        #expect(h.app.savedGateways.count == 1)
        h.app.draftText = "A before add"
        await h.app.connect(urlText: h.b.absoluteString, secret: "synthetic-new-password", password: true, setupCode: "", alias: "New target")
        if code == "NOT_PAIRED" {
            guard case .pairing = h.app.connectionState else { Issue.record("Expected pairing"); return }
        } else {
            guard case .failed = h.app.connectionState else { Issue.record("Expected authentication failure"); return }
        }
        #expect(h.app.savedGateways.count == 2)
        #expect(h.app.activeGateway?.endpoint == h.b.absoluteString)
        #expect(h.app.agentName == "エージェント")
        await h.app.switchGateway(h.profileA)
        #expect(h.app.connectionState == .connected)
        #expect(h.app.draftText == "A before add")
        #expect(h.app.activeGateway?.label == "Alpha")
        #expect(h.connections.made.last?.1.deviceToken == "synthetic-a")
        await h.app.disconnect()
    }

    @Test func legacyRestoreUsesUnmodifiedCredentialKeyAndConversationNamespace() async throws {
        let exact = "wss://Legacy.Example:443/deployment%2Fpath"
        let suite = "SavedGatewayTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(exact, forKey: "lastGateway")
        let file = profileFile(suite)
        defer { try? FileManager.default.removeItem(at: file) }
        let repository = LocalGatewayProfileRepository(defaults: defaults, file: file)
        let connections = SavedConnectionFixture()
        connections.credentials["gateway:" + gatewayHash(exact)] = GatewayCredentials(deviceToken: "synthetic-legacy")
        connections.services[exact] = SavedGatewayService("Legacy Agent")
        let disk = GatewayMemoryDisk(gatewayStore("Legacy draft"))
        let app = AppModel(persistenceFactory: { key in
            #expect(key == gatewayHash(exact)); return disk
        }, profileRepository: repository, connectionAccess: connections.access)
        await app.restore()
        #expect(app.connectionState == .connected)
        #expect(app.draftText == "Legacy draft")
        #expect(app.activeGateway?.endpoint == exact)
        #expect(connections.reads.first == "gateway:" + gatewayHash(exact))
        #expect(connections.made.last?.1.deviceToken == "synthetic-legacy")
        await app.disconnect()
    }

    @Test func aNewModelRestoresTheLastActiveProfileAndItsDraftWithoutRetypingCredentials() async throws {
        let h = try SavedGatewayHarness(); await h.app.restore()
        await h.app.switchGateway(h.profileB)
        h.app.draftText = "B before relaunch"
        await h.app.disconnect()
        let disks = [gatewayHash(h.a.absoluteString): h.diskA, gatewayHash(h.b.absoluteString): h.diskB]
        let restored = AppModel(persistenceFactory: { try #require(disks[$0]) }, profileRepository: h.repository, connectionAccess: h.connections.access)
        await restored.restore()
        #expect(restored.activeGateway?.endpoint == h.b.absoluteString)
        #expect(restored.draftText == "B before relaunch")
        #expect(restored.messages.map(\.text) == ["Agent B history"])
        #expect(h.connections.made.last?.1.password == "synthetic-b")
        await restored.disconnect()
    }

    @Test func deviceTokenRotationIsScopedToEndpointAndNeverEntersMetadata() async throws {
        let h = try SavedGatewayHarness()
        h.connections.services[h.a.absoluteString] = SavedGatewayService("Agent A", issuedToken: "synthetic-rotated-a")
        await h.app.restore()
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.a.absoluteString)]?.deviceToken == "synthetic-rotated-a")
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.b.absoluteString)]?.password == "synthetic-b")
        await h.app.retryConnection()
        #expect(h.connections.made.last?.1.deviceToken == "synthetic-rotated-a")
        #expect(h.app.activeGateway?.label == "Alpha")
        let json = String(decoding: try JSONEncoder().encode(h.repository.state), as: UTF8.self)
        #expect(!json.contains("synthetic-rotated-a"))
        await h.app.disconnect()
    }

    @Test func slowLoadKeepsActualSelectionAndFlushesEditsBeforePublishingDestination() async throws {
        let h = try SavedGatewayHarness(); await h.app.restore()
        await h.diskB.pauseLoad()
        let switching = Task { await h.app.switchGateway(h.profileB) }
        await h.diskB.waitForLoad()
        #expect(h.app.changingConnection)
        #expect(h.app.activeGateway?.endpoint == h.a.absoluteString)
        #expect(h.app.agentName == "エージェント")
        h.app.draftText = "A edited during B load"
        await h.app.switchGateway(h.profileA) // Guarded: the second switch must not start a service.
        #expect(h.connections.made.count == 1)
        await h.diskB.releaseLoad(); await switching.value
        #expect(h.app.activeGateway?.endpoint == h.b.absoluteString)
        #expect(await h.diskA.state.selectedDraft.text == "A edited during B load")
        #expect(h.app.draftText == "B draft")
        await h.app.disconnect()
    }

    @Test func backgroundAndCancelledLoadCannotPublishDestination() async throws {
        let h = try SavedGatewayHarness(); await h.app.restore()
        await h.diskB.pauseLoad()
        let switching = Task { await h.app.switchGateway(h.profileB) }
        await h.diskB.waitForLoad()
        await h.app.background()
        switching.cancel()
        await h.diskB.releaseLoad(); await switching.value
        #expect(h.app.connectionState == .disconnected)
        #expect(h.app.activeGateway?.endpoint == h.a.absoluteString)
        #expect(h.app.draftText == "A draft")
        #expect(h.repository.state.lastActiveEndpoint == h.a.absoluteString)
        #expect(h.connections.made.count == 1)
        #expect(await h.diskB.writes.isEmpty)
    }

    @Test func cancelledHandshakeCannotActivateOrRetainALiveConnection() async throws {
        let h = try SavedGatewayHarness(); await h.app.restore()
        let b = try #require(h.connections.services[h.b.absoluteString])
        await b.pauseConnect()
        let switching = Task { await h.app.switchGateway(h.profileB) }
        await b.waitForConnect()
        switching.cancel()
        await b.releaseConnect(); await switching.value
        #expect(h.app.connectionState == .disconnected)
        #expect(h.app.agentName == "エージェント")
        #expect(!h.app.changingConnection)
        #expect(await b.disconnectCount == 1)
    }

    @Test func aHandshakeCompletingAfterBackgroundCannotPublishHelloOrDeviceToken() async throws {
        let h = try SavedGatewayHarness(); await h.app.restore()
        let b = SavedGatewayService("Agent B", issuedToken: "synthetic-late-token")
        h.connections.services[h.b.absoluteString] = b
        await b.pauseConnect()
        let switching = Task { await h.app.switchGateway(h.profileB) }
        await b.waitForConnect()
        await h.app.background()
        await b.releaseConnect(); await switching.value
        #expect(h.app.connectionState == .disconnected)
        #expect(h.app.agentName == "エージェント")
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.b.absoluteString)]?.deviceToken == nil)
        #expect(h.connections.credentials["gateway:" + gatewayHash(h.b.absoluteString)]?.password == "synthetic-b")
        #expect(await b.disconnectCount == 1)
    }

    @Test func oldIdentityAfterSwitchCannotBleedAcrossIdenticalAgentIDs() async throws {
        let h = try SavedGatewayHarness(); await h.app.restore()
        let a = try #require(h.connections.services[h.a.absoluteString])
        await a.pauseIdentity()
        let oldIdentity = Task { await h.app.selectSession(sharedSession) }
        await a.waitForIdentity()
        await h.app.switchGateway(h.profileB)
        #expect(h.app.agentName == "Agent B")
        await a.releaseIdentity(); await oldIdentity.value
        #expect(h.app.agentName == "Agent B")
        #expect(h.app.messages.map(\.text) == ["Agent B history"])
        await h.app.disconnect()
    }

    @Test func pairingSetupCodeStaysInCredentialStoreAndReconnectReusesIt() async throws {
        let endpoint = URL(string: "wss://pairing.example/")!
        let repository = TestGatewayProfileRepository()
        let connections = SavedConnectionFixture()
        connections.services[endpoint.absoluteString] = SavedGatewayService("Pairing", failure: GatewayFailure(code: "NOT_PAIRED", message: "Synthetic pairing"))
        let disk = GatewayMemoryDisk()
        let app = AppModel(persistenceFactory: { _ in disk }, profileRepository: repository, connectionAccess: connections.access)
        let data = try JSONEncoder().encode(JSONValue.object(["url": .string(endpoint.absoluteString), "bootstrapToken": .string("synthetic-bootstrap-only-in-keychain")]))
        let code = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        await app.connect(urlText: "", secret: "", password: false, setupCode: code, alias: "Pairing target")
        #expect(app.savedGateways.count == 1)
        #expect(connections.made.last?.1.bootstrapToken == "synthetic-bootstrap-only-in-keychain")
        await app.retryConnection()
        #expect(connections.made.count == 2)
        #expect(connections.made.last?.1.bootstrapToken == "synthetic-bootstrap-only-in-keychain")
        let metadata = String(decoding: try JSONEncoder().encode(repository.state), as: UTF8.self)
        #expect(!metadata.contains("synthetic-bootstrap"))
        #expect(!metadata.contains(code))
        #expect(app.activeGateway?.label == "Pairing target")
        await app.disconnect()
    }

    @Test func demoKeepsSavedProfilesAndLastRealEndpoint() async throws {
        let repository = TestGatewayProfileRepository()
        let connections = SavedConnectionFixture()
        let endpoint = URL(string: "wss://real.example/")!
        connections.services[endpoint.absoluteString] = SavedGatewayService("Real")
        let realDisk = GatewayMemoryDisk(gatewayStore("real draft"))
        let demoDisk = GatewayMemoryDisk()
        let disks = [gatewayHash(endpoint.absoluteString): realDisk, gatewayHash("local-demo"): demoDisk]
        let app = AppModel(persistenceFactory: { try #require(disks[$0]) }, profileRepository: repository, connectionAccess: connections.access)
        await app.connect(urlText: endpoint.absoluteString, secret: "synthetic-token", password: false, setupCode: "", alias: "Real")
        await app.startDemo()
        #expect(app.isDemo)
        #expect(app.activeGateway == nil)
        #expect(app.savedGateways.count == 1)
        #expect(repository.state.lastActiveEndpoint == endpoint.absoluteString)
        #expect(connections.credentials["gateway:" + gatewayHash(endpoint.absoluteString)]?.token == "synthetic-token")
        let profile = try #require(app.savedGateways.first)
        await app.switchGateway(profile)
        #expect(!app.isDemo)
        #expect(app.activeGateway?.label == "Real")
        #expect(app.draftText == "real draft")
        #expect(!repository.state.useDemo)
        await app.disconnect()
    }
}
