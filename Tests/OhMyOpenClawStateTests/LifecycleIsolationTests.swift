import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor StoredConversations: ConversationPersisting {
    let seed: ConversationStore
    private var holdLoad: Bool
    private var holdSave: Bool
    private let loadStarted = AsyncStream<Void>.makeStream()
    private let saveStarted = AsyncStream<Void>.makeStream()
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadCount = 0
    private(set) var writes: [ConversationStore] = []
    init(_ seed: ConversationStore, holdLoad: Bool = false, holdSave: Bool = false) { self.seed = seed; self.holdLoad = holdLoad; self.holdSave = holdSave }
    func load() async throws -> ConversationStore {
        loadCount += 1
        if holdLoad { await withCheckedContinuation { loadWaiters.append($0); loadStarted.continuation.yield(()) } }
        return seed
    }
    func save(_ state: ConversationStore, revision: Int) async throws {
        if holdSave { await withCheckedContinuation { saveWaiters.append($0); saveStarted.continuation.yield(()) } }
        writes.append(state)
    }
    func waitForLoad() async { for await _ in loadStarted.stream { return } }
    func waitForSave() async { for await _ in saveStarted.stream { return } }
    func releaseLoads() { holdLoad = false; let waiters = loadWaiters; loadWaiters = []; for waiter in waiters { waiter.resume() } }
    func releaseSaves() { holdSave = false; let waiters = saveWaiters; saveWaiters = []; for waiter in waiters { waiter.resume() } }
    func pauseSaves() { holdSave = true }
}

private actor LifecycleGateway: GatewayServing {
    private(set) var disconnectCount = 0
    private let connectStarted = AsyncStream<Void>.makeStream()
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private let holdConnection: Bool
    init(holdConnection: Bool = false) { self.holdConnection = holdConnection }
    func connect() async throws -> GatewayHello {
        if holdConnection { await withCheckedContinuation { connectWaiter = $0; connectStarted.continuation.yield(()) } }
        return GatewayHello(payload: .object(["snapshot": .object(["sessionDefaults": .object([
            "defaultAgentId": .string("demo"), "mainSessionKey": .string("agent:demo:main"),
        ])])]))
    }
    func waitForConnect() async { for await _ in connectStarted.stream { return } }
    func releaseConnect() { connectWaiter?.resume(); connectWaiter = nil }
    func request(method: String, params: JSONValue) async throws -> JSONValue { .object([:]) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async { disconnectCount += 1 }
}

private func savedDraft(_ text: String) -> ConversationStore {
    var store = ConversationStore()
    let main = ChatSession(key: "agent:demo:main", agentID: "demo", sessionID: "demo-main", title: "Main", isMain: true)
    store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: text), for: main.id)
    return store
}

@Suite(.serialized)
@MainActor struct LifecycleIsolationTests {
    @Test func explicitDisconnectRemainsDisconnectedWhenTheHandshakeCompletesDuringItsSave() async {
        let state = savedDraft("retained draft")
        let disk = StoredConversations(state)
        let gateway = LifecycleGateway(holdConnection: true)
        let app = AppModel(service: gateway, initialStore: state, initialPersistence: disk, initialNamespace: "A")
        let connecting = Task { await app.establishConnection() }
        await gateway.waitForConnect()
        await disk.pauseSaves()
        let disconnecting = Task { await app.disconnect() }
        await disk.waitForSave()
        await gateway.releaseConnect()
        await disk.waitForSave()
        await disk.releaseSaves()
        await disconnecting.value
        await connecting.value
        #expect(app.connectionState == .disconnected)
        #expect(!app.canSend)
        #expect(app.draftText == "retained draft")
        #expect(await gateway.disconnectCount == 1)
    }

    @Test func staleBackgroundSaveCannotDisconnectAfterForegroundReturns() async {
        let state = savedDraft("foreground draft")
        let disk = StoredConversations(state, holdSave: true)
        let gateway = LifecycleGateway()
        let app = AppModel(service: gateway, initialStore: state, initialPersistence: disk, initialNamespace: "A")
        let leaving = Task { await app.background() }
        await disk.waitForSave()
        await app.foreground()
        await disk.releaseSaves()
        await leaving.value
        #expect(app.connectionState == .connected)
        #expect(await gateway.disconnectCount == 0)
    }

    @Test func overlappingSwitchDoesNotPublishAnIncomingStoreBeforeItsLoadCompletes() async {
        let diskA = StoredConversations(savedDraft("A private draft"))
        let diskB = StoredConversations(savedDraft("B saved draft"), holdLoad: true)
        let app = AppModel(service: LifecycleGateway(), initialStore: savedDraft("A private draft"), initialPersistence: diskA, initialNamespace: "A", persistenceFactory: { _ in diskB }, profileRepository: TestGatewayProfileRepository())
        let first = Task { await app.startDemo() }
        await diskB.waitForLoad()
        #expect(app.connectionState == .connecting)
        app.draftText = "A edited during load"
        let second = Task { await app.startDemo() }
        let ignoredDuplicate = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await second.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
            let finished = await group.next() ?? false
            await diskB.releaseLoads()
            group.cancelAll()
            return finished
        }
        await first.value
        #expect(ignoredDuplicate)
        #expect(await diskB.loadCount == 1)
        #expect(app.draftText == "B saved draft")
        #expect(await diskA.writes.last?.selectedDraft.text == "A edited during load")
        #expect(await diskB.writes.allSatisfy { !$0.selectedDraft.text.hasPrefix("A ") })
    }

    @Test func backgroundInvalidatesAStillLoadingDestinationWithoutOverwritingIt() async {
        let diskA = StoredConversations(savedDraft("A private draft"))
        let diskB = StoredConversations(savedDraft("B saved draft"), holdLoad: true)
        let app = AppModel(service: LifecycleGateway(), initialStore: savedDraft("A private draft"), initialPersistence: diskA, initialNamespace: "A", persistenceFactory: { _ in diskB }, profileRepository: TestGatewayProfileRepository())
        let switching = Task { await app.startDemo() }
        await diskB.waitForLoad()
        await app.background()
        await diskB.releaseLoads()
        await switching.value
        #expect(app.connectionState == .disconnected)
        #expect(app.draftText == "A private draft")
        #expect(await diskB.writes.isEmpty)
    }

    @Test func foregroundRestartsSavedDemoRestoreInterruptedDuringItsInitialLoad() async {
        let disk = StoredConversations(savedDraft("restored draft"), holdLoad: true)
        var profiles = GatewayProfiles(); profiles.useDemo = true
        let app = AppModel(persistenceFactory: { _ in disk }, profileRepository: TestGatewayProfileRepository(profiles))
        let restoring = Task { await app.restore() }
        await disk.waitForLoad()
        await app.background()
        await disk.releaseLoads()
        await restoring.value
        await app.foreground()
        #expect(app.connectionState == .connected)
        #expect(app.draftText == "restored draft")
        await app.disconnect()
    }

    @Test func editsDuringTheFinalOutgoingSaveStayWithTheirOriginalOwner() async {
        let diskA = StoredConversations(savedDraft("A initial"))
        let diskB = StoredConversations(savedDraft("B saved"), holdLoad: true)
        let app = AppModel(service: LifecycleGateway(), initialStore: savedDraft("A initial"), initialPersistence: diskA, initialNamespace: "A", persistenceFactory: { _ in diskB }, profileRepository: TestGatewayProfileRepository())
        let switching = Task { await app.startDemo() }
        await diskB.waitForLoad()
        app.draftText = "A first edit"
        await diskA.pauseSaves()
        await diskB.releaseLoads()
        await diskA.waitForSave()
        app.draftText = "A final edit"
        await diskA.releaseSaves()
        await switching.value
        #expect(await diskA.writes.last?.selectedDraft.text == "A final edit")
        #expect(app.draftText == "B saved")
        #expect(await diskB.writes.allSatisfy { !$0.selectedDraft.text.hasPrefix("A ") })
        await app.disconnect()
    }
}
