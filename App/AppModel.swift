import CryptoKit
import Foundation
import Observation
import OhMyOpenClawCore

protocol ConversationPersisting: Sendable {
    func load() async throws -> ConversationStore
    func save(_ state: ConversationStore, revision: Int) async throws
}

@Observable @MainActor
final class AppModel {
    var connectionState: ConnectionState = .disconnected
    var isDemo = false
    private var agentNames: [String: String] = [:]
    var agentName: String { selectedSession.flatMap { agentNames[$0.agentID] } ?? "エージェント" }
    /// An agent's name once this connection has looked it up, else its id.
    func agentName(for id: String) -> String { agentNames[id] ?? id }
    var models: [ModelOption] = []
    var errorMessage: String?
    var notice: String?
    var hasMoreHistory = false
    private var store = ConversationStore()
    private var promptRecords: [ApprovalPrompt] = [] {
        // An answer lives exactly as long as its prompt.
        didSet { promptAnswers = promptAnswers.filter { id, _ in promptRecords.contains { $0.id == id } } }
    }
    /// Answers typed into open questions, kept across thread switches.
    var promptAnswers: [String: String] = [:]
    private var promptTargets: [String: String] = [:]
    @ObservationIgnored private var resolvedPromptIDs = Set<String>()
    private var sendingTargets = Set<String>()
    @ObservationIgnored private var preparingRuns: [String: Bool] = [:] // Whether this preparation retries a possibly dispatched input.
    @ObservationIgnored private var cancelledPreparedRuns = Set<String>()

    @ObservationIgnored private var service: (any GatewayServing)?
    @ObservationIgnored private var hello: GatewayHello?
    private(set) var endpoint: URL?
    private(set) var gatewayProfiles = GatewayProfiles()
    @ObservationIgnored private var profilesLoaded = false
    @ObservationIgnored private let profileRepository: any GatewayProfilePersisting
    @ObservationIgnored private let connectionAccess: GatewayConnectionAccess
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var streamRevisions: [String: Int] = [:]
    @ObservationIgnored private var sessionRevisions: [String: Int] = [:]
    @ObservationIgnored private var pendingHistoryRefresh = Set<String>()
    @ObservationIgnored private var nextHistoryOffset = 0
    @ObservationIgnored private var loadedOlderHistory = false
    @ObservationIgnored private var persistence: (any ConversationPersisting)?
    @ObservationIgnored private var persistenceNamespace: String?
    @ObservationIgnored private let persistenceFactory: @Sendable (String) throws -> any ConversationPersisting
    @ObservationIgnored private var persistenceRevision = 0
    @ObservationIgnored private(set) var autoConnect = true
    @ObservationIgnored private var questionRecords: [String: JSONValue] = [:]
    @ObservationIgnored private var questionAnswers: [String: [String: JSONValue]] = [:]
    @ObservationIgnored private var currentSubscription: ChatSession?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private(set) var attemptedAutomaticRecovery = false
    private(set) var changingConnection = false
    @ObservationIgnored private var connectionSwitch: UUID?
    @ObservationIgnored private var sceneGeneration = UUID()
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var agentIdentityRequest = UUID()
    @ObservationIgnored private var agentIdentityTask: Task<Void, Never>?
    /// Who "me" is on this connection. Rendering uses `timelineViewer`.
    private(set) var viewer: ViewerIdentity = .unresolved
    @ObservationIgnored private(set) var viewerTask: Task<Void, Never>?

    var savedGateways: [SavedGateway] { gatewayProfiles.profiles }
    var activeGateway: SavedGateway? {
        guard !isDemo, let endpoint else { return nil }
        return savedGateways.first { $0.endpoint == endpoint.absoluteString }
    }
    var sessions: [ChatSession] { store.sessions }
    var selectedSession: ChatSession? { store.selectedSession }
    var selectedSessionKey: String? { selectedSession?.key }
    var composerContextID: String {
        [isDemo ? "local-demo" : endpoint?.absoluteString ?? "unconfigured", selectedSession?.agentID ?? "", selectedSession?.key ?? "", selectedSession?.sessionID ?? "", connectionGeneration.uuidString, selectionGeneration.uuidString].joined(separator: "|")
    }
    var messages: [ChatMessage] { store.selectedMessages.filter(\.isConversationMessage) }
    /// The viewer for attribution. While unresolved, the profile this Gateway named last keeps saved rows on their side.
    var timelineViewer: ViewerIdentity {
        if case .unresolved = viewer, let cached = store.viewerProfileID { return .profile(cached) }
        return viewer
    }
    var draftText: String {
        get { store.selectedDraft.text }
        set {
            guard let id = store.selectedID else { return }
            var draft = store.selectedDraft; draft.text = newValue
            store.setDraft(draft, for: id); scheduleSave()
        }
    }
    var attachments: [ChatAttachment] { store.selectedDraft.attachments }
    var activity: ActivityState { store.selectedID.flatMap { store.activities[$0] } ?? .idle }
    var selectedModelID: String? { selectedSession?.modelID }
    var selectedThinkingLevel: String? { selectedSession?.thinkingLevel }
    var thinkingLevels: [ThinkingLevel] { models.first(where: { $0.id == selectedModelID })?.thinkingLevels ?? [] }
    var prompts: [ApprovalPrompt] { promptRecords.filter { promptTargets[$0.id] == store.selectedID } }
    var canSend: Bool {
        guard connectionState == .connected, let selectedSession, activity == .idle,
              !sendingTargets.contains(selectedSession.id), !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        if selectedSession.sessionID == nil, store.pending.values.contains(where: { $0.target.id == selectedSession.id }),
           store.unresolvedSubmission(matching: store.selectedDraft, for: selectedSession) == nil { return false }
        return true
    }

    init(service: (any GatewayServing)? = nil, initialStore: ConversationStore = ConversationStore(), policy: JSONValue = .null,
         initialPersistence: (any ConversationPersisting)? = nil, initialNamespace: String? = nil,
         persistenceFactory: @escaping @Sendable (String) throws -> any ConversationPersisting = { try ConversationPersistence(namespace: $0) },
         profileRepository: any GatewayProfilePersisting = LocalGatewayProfileRepository(),
         connectionAccess: GatewayConnectionAccess = .live) {
        self.service = service; self.store = initialStore
        self.profileRepository = profileRepository; self.connectionAccess = connectionAccess
        self.persistence = initialPersistence; self.persistenceNamespace = initialNamespace; self.persistenceFactory = persistenceFactory
        if service != nil { connectionState = .connected; hello = GatewayHello(payload: .object(["policy": policy])) }
    }

    func restore() async {
        guard service == nil, !restoring, !changingConnection else { return }
        restoring = true
        defer { restoring = false }
        do { try loadProfiles() } catch { errorMessage = error.localizedDescription; return }
        if gatewayProfiles.useDemo { await startDemo(); return }
        guard let text = gatewayProfiles.lastActiveEndpoint,
              let profile = savedGateways.first(where: { $0.endpoint == text }) else { return }
        await switchGateway(profile)
    }

    func startDemo() async {
        guard let transaction = beginConnectionSwitch() else { return }
        defer { finishConnectionSwitch() }
        reconnectTask?.cancel(); attemptedAutomaticRecovery = false
        await retireConnection()
        do {
            try validateConnectionSwitch(transaction)
            try loadProfiles()
            try await loadStore(namespace: "local-demo", transaction: transaction)
            try validateConnectionSwitch(transaction)
            isDemo = true; endpoint = nil; autoConnect = true
            var profiles = gatewayProfiles; profiles.useDemo = true
            try profileRepository.save(profiles); gatewayProfiles = profiles
            // A fresh deterministic service owns its own history; cached drafts remain useful.
            store.pending = [:]
            service = DemoGateway()
            await establishConnection()
        } catch is CancellationError { if service == nil { connectionState = .disconnected } }
        catch { fail(error) }
    }

    func switchGateway(_ profile: SavedGateway) async {
        do { try loadProfiles() } catch { errorMessage = error.localizedDescription; return }
        guard savedGateways.contains(where: { $0.endpoint == profile.endpoint }) else { return }
        await connect(urlText: profile.endpoint, secret: "", password: false, setupCode: "", savedEndpoint: profile.endpoint)
    }

    func renameGateway(_ profile: SavedGateway, alias: String) {
        do {
            try loadProfiles()
            var profiles = gatewayProfiles; profiles.rename(endpoint: profile.endpoint, alias: alias)
            try profileRepository.save(profiles); gatewayProfiles = profiles
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteGateway(_ profile: SavedGateway) async -> Bool {
        guard !changingConnection, connectionState != .connecting, !inBackground, !Task.isCancelled else { return false }
        notice = nil
        let previousState = connectionState
        let transaction = endpoint?.absoluteString == profile.endpoint ? beginConnectionSwitch() : nil
        defer {
            if let transaction {
                if connectionSwitch == transaction, connectionState == .connecting { connectionState = previousState }
                finishConnectionSwitch()
            }
        }
        do {
            try loadProfiles()
            guard savedGateways.contains(where: { $0.id == profile.id }) else { return true }
            if let transaction {
                _ = try await persistForSwitch(transaction)
                try validateConnectionSwitch(transaction)
            }

            let key = credentialKey(try profile.url)
            var profiles = gatewayProfiles; profiles.remove(endpoint: profile.endpoint)
            try profileRepository.save(profiles)
            do { try connectionAccess.delete(key) }
            catch {
                try profileRepository.save(gatewayProfiles)
                throw error
            }
            finishCredentialRemoval(&profiles)
            gatewayProfiles = profiles

            if transaction != nil {
                reconnectTask?.cancel(); autoConnect = false; endpoint = nil
                connectionState = .disconnected; errorMessage = nil
                replaceStore(ConversationStore(), persistence: nil, namespace: nil)
                await retireConnection()
            }
            return true
        } catch is CancellationError { return false }
        catch { notice = error.localizedDescription; return false }
    }

    private func loadProfiles() throws {
        guard !profilesLoaded else { return }
        var profiles = try profileRepository.load()
        if let endpoint = profiles.pendingCredentialRemoval {
            try connectionAccess.delete(credentialKey(try SavedGateway.exactURL(endpoint)))
            finishCredentialRemoval(&profiles)
        }
        gatewayProfiles = profiles; profilesLoaded = true
    }

    private func finishCredentialRemoval(_ profiles: inout GatewayProfiles) {
        profiles.pendingCredentialRemoval = nil
        // If saving fails, launch can retry the idempotent Keychain removal from the saved marker.
        try? profileRepository.save(profiles)
    }

    func connect(urlText: String, secret: String, password: Bool, setupCode: String, alias: String? = nil) async {
        await connect(urlText: urlText, secret: secret, password: password, setupCode: setupCode, alias: alias, savedEndpoint: nil)
    }

    private func connect(urlText: String, secret: String, password: Bool, setupCode: String, alias: String? = nil, savedEndpoint: String?) async {
        guard !changingConnection, !inBackground, !Task.isCancelled else { return }
        var transactionStarted = false
        defer { if transactionStarted { finishConnectionSwitch() } }
        reconnectTask?.cancel(); attemptedAutomaticRecovery = false
        do {
            try loadProfiles()
            let url: URL
            let credentials: GatewayCredentials
            if !setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let setup = try GatewayEndpoint.decodeSetupCode(setupCode)
                url = setup.url; credentials = GatewayCredentials(bootstrapToken: setup.bootstrapToken)
            } else {
                let exactEndpoint = savedEndpoint ?? savedGateways.first(where: { $0.endpoint == urlText })?.endpoint
                url = try exactEndpoint.map { try SavedGateway.exactURL($0) } ?? GatewayEndpoint.parse(urlText)
                let value = secret.isEmpty ? nil : secret
                if value == nil { credentials = try connectionAccess.read(credentialKey(url)) ?? GatewayCredentials() }
                else { credentials = password ? GatewayCredentials(password: value) : GatewayCredentials(token: value) }
            }
            guard let transaction = beginConnectionSwitch() else { return }
            transactionStarted = true
            await retireConnection()
            try validateConnectionSwitch(transaction)
            try connectionAccess.write(credentials, credentialKey(url))
            try await loadStore(namespace: url.absoluteString, transaction: transaction)
            try validateConnectionSwitch(transaction)
            endpoint = url; isDemo = false; autoConnect = true
            var profiles = gatewayProfiles; try profiles.activate(url, alias: alias)
            try profileRepository.save(profiles); gatewayProfiles = profiles
            service = try connectionAccess.makeService(url, credentials)
            await establishConnection()
        } catch is CancellationError { if service == nil { connectionState = .disconnected } }
        catch { if connectionState == .connected { errorMessage = error.localizedDescription } else { fail(error) } }
    }

    func retryConnection() async {
        guard !changingConnection else { return }
        autoConnect = true
        reconnectTask?.cancel(); attemptedAutomaticRecovery = false
        await reconnect()
    }

    private func reconnect() async {
        guard !changingConnection, connectionState != .connecting else { return }
        if isDemo { await startDemo(); return }
        guard let endpoint else { return }
        guard let transaction = beginConnectionSwitch() else { return }
        defer { finishConnectionSwitch() }
        await retireConnection()
        do {
            try validateConnectionSwitch(transaction)
            let credentials = try connectionAccess.read(credentialKey(endpoint)) ?? GatewayCredentials()
            service = try connectionAccess.makeService(endpoint, credentials)
            await establishConnection()
        } catch is CancellationError { if service == nil { connectionState = .disconnected } }
        catch { fail(error) }
    }

    func foreground() async {
        inBackground = false; sceneGeneration = UUID()
        if !restoring, !changingConnection, autoConnect, connectionState != .connected, connectionState != .connecting {
            if endpoint == nil, !isDemo { await restore() }
            else { await retryConnection() }
        }
    }
    func background() async {
        let scene = UUID(); sceneGeneration = scene; inBackground = true
        reconnectTask?.cancel()
        do { try await persistNow() } catch { errorMessage = error.localizedDescription }
        guard inBackground, sceneGeneration == scene else { return }
        connectionSwitch = nil
        connectionState = .disconnected
        await retireConnection()
    }
    func disconnect() async {
        reconnectTask?.cancel()
        autoConnect = false; connectionSwitch = nil; connectionState = .disconnected
        let generation = connectionGeneration
        do { try await persistNow() } catch { errorMessage = error.localizedDescription }
        guard generation == connectionGeneration else { return }
        connectionState = .disconnected
        await retireConnection()
    }

    private func beginConnectionSwitch() -> UUID? {
        guard !changingConnection, !inBackground, !Task.isCancelled else { return nil }
        changingConnection = true; connectionState = .connecting
        let transaction = UUID(); connectionSwitch = transaction
        return transaction
    }
    private func validateConnectionSwitch(_ transaction: UUID) throws {
        guard connectionSwitch == transaction, !inBackground, !Task.isCancelled else { throw CancellationError() }
    }
    private func finishConnectionSwitch() {
        changingConnection = false; connectionSwitch = nil
        if !inBackground, !Task.isCancelled, autoConnect, connectionState == .disconnected {
            reconnectTask = Task { [weak self] in
                guard !Task.isCancelled, let self, !self.inBackground, self.autoConnect, !self.changingConnection, self.connectionState == .disconnected else { return }
                self.reconnectTask = nil
                if self.endpoint == nil, !self.isDemo { await self.restore() }
                else { await self.reconnect() }
            }
        }
    }

    func establishConnection() async {
        guard let service else { return }
        let generation = connectionGeneration
        connectionState = .connecting; errorMessage = nil; notice = nil
        do {
            let stream = await service.events()
            guard connectionGeneration == generation, !inBackground else { return }
            try Task.checkCancellation()
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled, let self, self.connectionGeneration == generation else { break }
                    await self.handle(event)
                }
            }
            let received = try await service.connect()
            guard connectionGeneration == generation, !inBackground else { return }
            try Task.checkCancellation()
            hello = received
            adoptViewer(.fromHello(received.payload))
            if case .unresolved = viewer, received.payload["features"]["methods"].arrayValue?.contains(.string("users.self")) == true {
                // The profile lookup can wait on an identity sync, so it never holds up the connection.
                viewerTask = Task { [weak self] in await self?.resolveViewerProfile(generation: generation) }
            }
            if let endpoint, let token = received.payload["auth"]["deviceToken"].stringValue {
                let old = try connectionAccess.read(credentialKey(endpoint))
                let scopes = received.payload["auth"]["scopes"].arrayValue?.compactMap(\.stringValue)
                let storedScopes = old?.deviceToken == token ? (old?.scopes ?? scopes) : scopes
                try connectionAccess.write(GatewayCredentials(deviceToken: token, scopes: storedScopes), credentialKey(endpoint))
            }
            let defaults = received.snapshot["sessionDefaults"]
            guard let agentID = defaults["defaultAgentId"].stringValue, let mainKey = defaults["mainSessionKey"].stringValue else {
                throw GatewayFailure(code: "UNSUPPORTED_GATEWAY", message: "接続先がメインチャットの情報を返しませんでした。Gateway の対応バージョンを確認してください。")
            }
            let existingMain = store.sessions.first { $0.agentID == agentID && $0.key == mainKey }
            store.upsertSession(ChatSession(key: mainKey, agentID: agentID, sessionID: existingMain?.sessionID, title: "メインチャット", isMain: true, modelID: existingMain?.modelID, thinkingLevel: existingMain?.thinkingLevel))
            if store.selectedSession == nil { store.selectedID = agentID + "|" + mainKey }
            attemptedAutomaticRecovery = false
            connectionState = .connected
            do { try await refreshRoster() }
            catch { if connectionGeneration == generation { notice = "会話一覧を更新できませんでした。再接続でやり直せます。" } }
            guard connectionGeneration == generation, !inBackground else { return }
            try Task.checkCancellation()
            if let selected = store.selectedSession { await selectSession(selected) }
            guard connectionGeneration == generation, !inBackground else { return }
            try Task.checkCancellation()
            try await persistNow()
        } catch {
            guard connectionGeneration == generation, !inBackground else { return }
            if error is CancellationError || Task.isCancelled {
                connectionState = .disconnected
                await retireConnection()
                return
            }
            if let failure = error as? GatewayFailure, failure.code == "NOT_PAIRED" || failure.details["code"].stringValue == "PAIRING_REQUIRED" {
                connectionState = .pairing(requestID: failure.details["requestId"].stringValue ?? "", message: "Gateway 側でこの端末を承認してから、再接続してください。")
            } else { fail(error) }
        }
    }

    private func resolveViewerProfile(generation: UUID) async {
        guard let service else { return }
        do {
            let result = try await service.request(method: "users.self", params: .object([:]))
            guard connectionGeneration == generation, !Task.isCancelled else { return }
            adoptViewer(.fromUsersSelf(result))
        } catch let failure as GatewayFailure where failure.code == "FORBIDDEN" {
            guard connectionGeneration == generation, !Task.isCancelled else { return }
            adoptViewer(.profileless)
        } catch {}
    }

    private func adoptViewer(_ identity: ViewerIdentity) {
        viewer = identity
        let remembered: String?
        switch identity {
        case .unresolved: return
        case .profileless: remembered = nil
        case .profile(let id): remembered = id
        }
        guard store.viewerProfileID != remembered else { return }
        store.viewerProfileID = remembered; scheduleSave()
    }

    private func retireConnection() async {
        connectionGeneration = UUID(); selectionGeneration = UUID()
        agentIdentityRequest = UUID(); agentIdentityTask?.cancel(); agentIdentityTask = nil
        viewerTask?.cancel(); viewerTask = nil; viewer = .unresolved
        agentNames = [:]
        eventTask?.cancel(); eventTask = nil; refreshTask?.cancel(); refreshTask = nil
        let previous = service; service = nil; hello = nil; currentSubscription = nil
        promptRecords = []; promptTargets = [:]; questionRecords = [:]; questionAnswers = [:]
        resolvedPromptIDs = []
        store.retireTransientState()
        await previous?.disconnect()
    }

    func newSideChat() async {
        agentIdentityTask?.cancel(); agentIdentityTask = nil
        guard let current = selectedSession ?? sessions.first(where: \.isMain) else { return }
        let session = ChatSession(key: "local:" + UUID().uuidString, agentID: current.agentID, title: "新しいサイドチャット")
        store.upsertSession(session); store.selectedID = session.id; selectionGeneration = UUID()
        models = []; hasMoreHistory = false; loadedOlderHistory = false; scheduleSave()
        await refreshModels(for: session)
        await refreshAgentName(for: session)
    }

    func selectSession(_ session: ChatSession) async {
        agentIdentityTask?.cancel(); agentIdentityTask = nil
        store.selectedID = session.id; selectionGeneration = UUID()
        errorMessage = nil; hasMoreHistory = false; nextHistoryOffset = 0; loadedOlderHistory = false; models = []
        scheduleSave()
        guard connectionState == .connected, let service else { return }
        let selection = selectionGeneration; let generation = connectionGeneration
        if let previous = currentSubscription, previous.id != session.id {
            _ = try? await service.request(method: "sessions.messages.unsubscribe", params: targetParams(previous, keyName: "key", extra: ["subscriptionId": .string("foreground")], includeSessionID: false))
        }
        guard selectionGeneration == selection, connectionGeneration == generation else { return }
        if !session.key.hasPrefix("local:") {
            do {
                _ = try await service.request(method: "sessions.messages.subscribe", params: targetParams(session, keyName: "key", extra: ["subscriptionId": .string("foreground"), "includeApprovals": .bool(true)], includeSessionID: false))
                guard selectionGeneration == selection, connectionGeneration == generation else { return }
                currentSubscription = session
                try await refreshHistory(for: session)
            } catch { if selectionGeneration == selection { errorMessage = error.localizedDescription } }
        }
        guard selectionGeneration == selection, connectionGeneration == generation else { return }
        await refreshModels(for: store.selectedSession ?? session)
        await refreshPrompts()
        guard selectionGeneration == selection, connectionGeneration == generation else { return }
        await refreshAgentName(for: session)
    }

    private func refreshAgentName(for target: ChatSession) async {
        guard connectionState == .connected, selectedSession?.agentID == target.agentID, let service else { return }
        let generation = connectionGeneration, selection = selectionGeneration, request = UUID()
        agentIdentityRequest = request
        guard let result = try? await service.request(method: "agent.identity.get", params: .object(["agentId": .string(target.agentID)])),
              !Task.isCancelled, connectionGeneration == generation, selectionGeneration == selection,
              agentIdentityRequest == request, selectedSession?.agentID == target.agentID,
              result["agentId"].stringValue == nil || result["agentId"].stringValue == target.agentID,
              let name = result["name"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        agentNames[target.agentID] = name
    }

    /// Sends only while the composer still shows `context`, so a send queued in one
    /// thread never takes the draft of a thread chosen after it.
    func send(expecting context: String) async {
        guard composerContextID == context else { return }
        await send()
    }

    func send() async {
        guard canSend, let target = selectedSession else { return }
        if let existing = store.unresolvedSubmission(matching: store.selectedDraft, for: target) {
            await retryPending(existing.id, consumingDraft: true)
            return
        }
        errorMessage = nil
        do {
            // Reserve immutable input before creation, disk IO, or subscription can suspend.
            let submission = try store.prepareSubmission(for: target, policy: hello?.policy ?? .null)
            await sendPrepared(submission)
        } catch { errorMessage = error.localizedDescription }
    }

    private func sendPrepared(_ original: PendingSubmission, isRetry: Bool = false) async {
        guard let service, !sendingTargets.contains(original.target.id) else { return }
        let originalID = original.target.id
        sendingTargets.insert(originalID)
        preparingRuns[original.id] = isRetry
        var workingTargetID = originalID
        defer {
            preparingRuns[original.id] = nil; cancelledPreparedRuns.remove(original.id)
            sendingTargets.remove(originalID); sendingTargets.remove(workingTargetID)
            if pendingHistoryRefresh.contains(originalID) || pendingHistoryRefresh.contains(workingTargetID) { scheduleQuietRefresh() }
        }
        let generation = connectionGeneration
        var submission = original
        var target = submission.target
        do {
            // No network mutation precedes durable custody of the submitted bytes.
            try await persistNow()
            guard connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) else { return }
            if target.sessionID == nil {
                var creation = store.creationRequests[target.id]
                if creation != nil {
                    guard let issuedAt = store.creationIssuedAt?[target.id], Date().timeIntervalSince(issuedAt) < 240 else {
                        throw GatewayFailure(code: "CREATION_OUTCOME_UNKNOWN", message: "前回の会話作成を確認できません。重複を防ぐため、会話一覧に作成済みの会話がないか確認してください。入力はこの端末に残っています。")
                    }
                }
                if creation == nil {
                    var body: [String: JSONValue] = ["agentId": .string(target.agentID), "idempotencyKey": .string(UUID().uuidString), "titleSource": .string(String(submission.message.text.prefix(1_000)))]
                    if !target.key.hasPrefix("local:") { body["key"] = .string(target.key) }
                    if let model = target.modelID { body["model"] = .string(model) }
                    if let thinking = target.thinkingLevel { body["thinkingLevel"] = .string(thinking) }
                    creation = .object(body); store.creationRequests[target.id] = creation
                    if store.creationIssuedAt == nil { store.creationIssuedAt = [:] }
                    store.creationIssuedAt?[target.id] = Date()
                    try await persistNow()
                }
                guard connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) else { return }
                let result = try await service.request(method: "sessions.create", params: creation!)
                guard connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) else { return }
                guard let key = result["key"].stringValue else { throw GatewayFailure(code: "INVALID_RESPONSE", message: "新しい会話の保存先を確認できませんでした。") }
                guard target.key.hasPrefix("local:") || key == target.key else { throw GatewayFailure(code: "SESSION_CHANGED", message: "メインチャットの保存先を確認できませんでした。") }
                let created = parseSession(result["entry"], fallback: ChatSession(key: key, agentID: target.agentID, sessionID: result["sessionId"].stringValue, title: target.title, isMain: target.isMain))
                submission = try store.materializeSubmission(submission.id, as: created)
                store.creationRequests[originalID] = nil; store.creationIssuedAt?[originalID] = nil
                target = submission.target
                workingTargetID = target.id; sendingTargets.insert(workingTargetID)
                try await persistNow()
                guard connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) else { return }
                // Subscribe before sending so the first delta cannot be missed.
                if store.selectedID == target.id {
                    _ = try await service.request(method: "sessions.messages.subscribe", params: targetParams(target, keyName: "key", extra: ["subscriptionId": .string("foreground"), "includeApprovals": .bool(true)], includeSessionID: false))
                    guard connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) else { return }
                    if store.selectedID == target.id { currentSubscription = target }
                }
            }
            guard target.sessionID != nil else { throw GatewayFailure(code: "SESSION_UNKNOWN", message: "会話の保存先を確認中です。会話を開き直してから送信してください。") }
            guard connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) else { return }
            preparingRuns[original.id] = nil
            await dispatch(submission, through: service, generation: generation)
        } catch {
            if connectionGeneration == generation, !cancelledPreparedRuns.contains(original.id) {
                // A fresh input has not been dispatched, but an earlier retry may
                // already exist remotely and must keep its idempotency identity.
                if isRetry { store.markUncertain(submission.id) }
                else { store.reject(submission.id) }
                errorMessage = error.localizedDescription
                scheduleSave()
            }
        }
    }

    func retryPending(_ messageID: String, consumingDraft: Bool = false) async {
        guard service != nil, connectionState == .connected else { return }
        do {
            var submission = try store.retrySubmission(messageID)
            guard !sendingTargets.contains(submission.target.id) else { return }
            guard (store.activities[submission.target.id] ?? .idle) == .idle, store.activeRunIDs[submission.target.id] == nil else {
                throw GatewayFailure(code: "RUN_IN_PROGRESS", message: "現在の応答が終わってから、前のメッセージを再試行してください。")
            }
            submission = try store.prepareRetry(submission.id, consumingDraft: consumingDraft)
            store.activeRunIDs[submission.target.id] = submission.id; store.activities[submission.target.id] = .working
            await sendPrepared(submission, isRetry: true)
        } catch { errorMessage = error.localizedDescription }
    }

    private func dispatch(_ submission: PendingSubmission, through service: any GatewayServing, generation: UUID) async {
        do {
            let acknowledgment = try await service.request(method: "chat.send", params: submission.params)
            guard connectionGeneration == generation else { return }
            store.acknowledge(submission.id)
            try await persistNow()
            if acknowledgment["status"].stringValue == "ok" {
                try await refreshHistory(for: submission.target)
            }
        } catch {
            guard connectionGeneration == generation else { return }
            if let failure = error as? GatewayFailure, ["INVALID_REQUEST", "FORBIDDEN", "NOT_FOUND", "PAYLOAD_TOO_LARGE"].contains(failure.code) || failure.details["mutationAccepted"].boolValue == false {
                store.reject(submission.id)
                errorMessage = failure.message
            } else {
                store.markUncertain(submission.id)
                errorMessage = "送信結果を確認できませんでした。メッセージは端末に保存されています。再接続後、同じメッセージを確認できます。"
            }
            scheduleSave()
        }
    }

    func stop() async {
        guard let target = selectedSession, let runID = store.activeRunIDs[target.id], let service else { return }
        do {
            if let isRetry = preparingRuns[runID] {
                cancelledPreparedRuns.insert(runID)
                if !isRetry {
                    store.reject(runID)
                    try await persistNow()
                    return
                }
                // A retry may already exist remotely: cancel this preparation and still abort that run.
            }
            _ = try await service.request(method: "chat.abort", params: targetParams(target, extra: ["runId": .string(runID), "userInitiated": .bool(true)]))
            // Acknowledgment is not a terminal stream event. Refresh to settle authoritative state.
            try await refreshHistory(for: target)
        } catch { errorMessage = "停止を確認できませんでした。接続を確認して、もう一度停止してください。" }
    }

    /// The Gateway's per-image ceiling from hello-ok.policy, when it advertises one.
    var imageAttachmentLimit: Int? { hello?.policy["attachments"]["maxImageBytes"].intValue }

    func addAttachment(data: Data, fileName: String, mimeType: String) {
        guard let id = store.selectedID else { return }
        let maxBytes = mimeType.hasPrefix("image/") ? hello?.policy["attachments"]["maxImageBytes"].intValue : hello?.policy["attachments"]["maxBytes"].intValue
        if let maxBytes, data.count > maxBytes { errorMessage = "「\(fileName)」は接続先のサイズ上限を超えています。"; return }
        var draft = store.selectedDraft; draft.attachments.append(ChatAttachment(fileName: fileName, mimeType: mimeType, data: data))
        store.setDraft(draft, for: id); scheduleSave()
    }

    func loadAttachment(_ attachment: ChatAttachment, session: ChatSession) async throws -> Data {
        let context = composerContextID
        guard selectedSession?.id == session.id, selectedSession?.sessionID == session.sessionID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "会話を開き直して添付ファイルを読み込んでください。")
        }
        if !attachment.data.isEmpty { return attachment.data }
        guard connectionState == .connected, let service, let endpoint else {
            throw GatewayFailure(code: "NOT_CONNECTED", message: "Gateway に接続してから添付ファイルを読み込んでください。")
        }
        let data = try await GatewayArtifactLoader.load(attachment, session: session, service: service, endpoint: endpoint)
        guard composerContextID == context, selectedSession?.sessionID == session.sessionID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "接続または会話が変わったため読み込みを中断しました。")
        }
        return data
    }
    func removeAttachment(_ id: String) {
        guard let target = store.selectedID else { return }
        var draft = store.selectedDraft; draft.attachments.removeAll { $0.id == id }
        store.setDraft(draft, for: target); scheduleSave()
    }

    func setModel(_ id: String?) async { await patchSelection(model: id, thinking: nil, changeModel: true) }
    func setThinking(_ id: String?) async { await patchSelection(model: nil, thinking: id, changeModel: false) }
    private func patchSelection(model: String?, thinking: String?, changeModel: Bool) async {
        guard var target = selectedSession else { return }
        let old = target
        if changeModel { target.modelID = model; target.thinkingLevel = nil } else { target.thinkingLevel = thinking }
        if target.key.hasPrefix("local:") { store.upsertSession(target); scheduleSave(); return }
        guard let service else { return }
        var extra: [String: JSONValue] = changeModel ? ["model": model.map(JSONValue.string) ?? .null, "thinkingLevel": .null] : ["thinkingLevel": thinking.map(JSONValue.string) ?? .null]
        if let id = old.sessionID { extra["expectedSessionId"] = .string(id) }
        let generation = connectionGeneration
        do {
            let result = try await service.request(method: "sessions.patch", params: targetParams(old, keyName: "key", extra: extra, includeSessionID: false))
            guard connectionGeneration == generation, store.sessions.first(where: { $0.id == old.id })?.sessionID == old.sessionID else { return }
            store.upsertSession(parseSession(result["entry"], fallback: target)); scheduleSave()
            await refreshModels(for: target)
        } catch { if connectionGeneration == generation { errorMessage = error.localizedDescription } }
    }

    func renameSession(_ session: ChatSession, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return }
        if session.key.hasPrefix("local:") { var changed = session; changed.title = trimmed; store.upsertSession(changed); scheduleSave(); return }
        guard let service else { return }
        let generation = connectionGeneration
        do {
            let result = try await service.request(method: "sessions.patch", params: targetParams(session, keyName: "key", extra: ["label": .string(trimmed)], includeSessionID: false))
            guard connectionGeneration == generation, store.sessions.first(where: { $0.id == session.id })?.sessionID == session.sessionID else { return }
            var changed = session; changed.title = trimmed
            store.upsertSession(parseSession(result["entry"], fallback: changed)); scheduleSave()
        } catch { if connectionGeneration == generation { errorMessage = error.localizedDescription } }
    }

    func loadOlderHistory() async {
        guard hasMoreHistory, let target = selectedSession, let service else { return }
        let generation = connectionGeneration; let selection = selectionGeneration
        do {
            let result = try await service.request(method: "chat.history", params: targetParams(target, extra: ["limit": .number(100), "offset": .number(Double(nextHistoryOffset))], includeSessionID: false))
            guard connectionGeneration == generation, selectionGeneration == selection, selectedSession?.sessionID == target.sessionID else { return }
            guard let pageSessionID = result["sessionId"].stringValue, pageSessionID == target.sessionID else {
                try await refreshHistory(for: target)
                return
            }
            let older = ConversationStore.parseMessages(result["messages"].arrayValue ?? [], fallbackPrefix: "older:\(nextHistoryOffset)")
            var current = store.transcripts[target.id] ?? []
            let known = Set(current.map(\.id))
            current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
            store.transcripts[target.id] = current
            if !older.isEmpty { loadedOlderHistory = true }
            hasMoreHistory = result["hasMore"].boolValue ?? false
            nextHistoryOffset = result["nextOffset"].intValue ?? nextHistoryOffset + older.count
            scheduleSave()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshRoster() async throws {
        guard let service else { return }
        let generation = connectionGeneration
        let revisions = sessionRevisions
        let result = try await service.request(method: "sessions.subscribe", params: .object(["limit": .number(100)]))
        guard generation == connectionGeneration else { return }
        for row in result["list"]["sessions"].arrayValue ?? result["sessions"].arrayValue ?? [] {
            if let parsed = sessionFromRow(row), sessionRevisions[parsed.id, default: 0] == revisions[parsed.id, default: 0] { store.upsertSession(parsed) }
        }
        scheduleSave()
    }

    func refreshHistory(for target: ChatSession) async throws {
        guard !target.key.hasPrefix("local:"), let service else { return }
        guard !sendingTargets.contains(target.id) else {
            pendingHistoryRefresh.insert(target.id)
            return
        }
        let generation = connectionGeneration
        let revision = streamRevisions[target.id, default: 0]
        let activeRunBeforeRequest = store.activeRunIDs[target.id]
        let runIDs = store.pending.values.filter { $0.target.id == target.id && $0.target.sessionID == target.sessionID }.map { JSONValue.string($0.id) }
        var extra: [String: JSONValue] = ["limit": .number(100)]
        if !runIDs.isEmpty { extra["inputRunIds"] = .array(Array(runIDs.prefix(50))) }
        // History's sessionId belongs to messageId anchors, not current-transcript reads.
        let result = try await service.request(method: "chat.history", params: targetParams(target, extra: extra, includeSessionID: false))
        guard generation == connectionGeneration, let current = store.sessions.first(where: { $0.id == target.id }), current.sessionID == target.sessionID else { return }
        guard streamRevisions[target.id, default: 0] == revision, store.activeRunIDs[target.id] == activeRunBeforeRequest else {
            pendingHistoryRefresh.insert(target.id)
            scheduleQuietRefresh(); return
        }
        var resolved = current
        if let physicalID = result["sessionId"].stringValue { resolved.sessionID = physicalID }
        if let model = result["sessionInfo"]["model"].stringValue { resolved.modelID = qualifiedModel(id: model, provider: result["sessionInfo"]["modelProvider"].stringValue) }
        if let thinking = result["sessionInfo"]["thinkingLevel"].stringValue { resolved.thinkingLevel = thinking }
        store.upsertSession(resolved)
        let preserved = store.applyHistory(result, for: resolved, preservingOlderHistory: store.selectedID == target.id && loadedOlderHistory && resolved.sessionID == current.sessionID)
        pendingHistoryRefresh.remove(target.id)
        if store.selectedID == target.id {
            if preserved == 0 {
                hasMoreHistory = result["hasMore"].boolValue ?? false
                loadedOlderHistory = false
            }
            nextHistoryOffset = (result["nextOffset"].intValue ?? result["messages"].arrayValue?.count ?? 0) + preserved
        }
        scheduleSave()
    }

    private func refreshModels(for target: ChatSession) async {
        guard let service else { return }
        let generation = connectionGeneration
        do {
            let params: JSONValue = target.key.hasPrefix("local:") ? .object(["agentId": .string(target.agentID), "includeDetails": .bool(true)]) : .object(["agentId": .string(target.agentID), "sessionKey": .string(target.key), "includeDetails": .bool(true)])
            let result = try await service.request(method: "models.list", params: params)
            guard generation == connectionGeneration, store.selectedID == target.id else { return }
            models = (result["models"].arrayValue ?? []).compactMap { row in
                guard let id = row["id"].stringValue, row["manualSelectionAllowed"].boolValue != false, row["available"].boolValue != false else { return nil }
                let levels = (row["thinkingLevels"].arrayValue ?? []).compactMap { level -> ThinkingLevel? in
                    guard let id = level["id"].stringValue ?? level.stringValue else { return nil }
                    return ThinkingLevel(id: id, label: level["label"].stringValue ?? id)
                }
                return ModelOption(id: qualifiedModel(id: id, provider: row["provider"].stringValue), name: row["name"].stringValue ?? id, thinkingLevels: levels)
            }
        } catch { if generation == connectionGeneration, store.selectedID == target.id { notice = "モデル一覧を取得できませんでした。現在の設定で会話は続けられます。" } }
    }

    private func handle(_ event: GatewayEvent) async {
        if event.name == "client.disconnected" {
            store.retireTransientState(); connectionState = .disconnected; scheduleSave()
            if autoConnect, !attemptedAutomaticRecovery {
                attemptedAutomaticRecovery = true
                reconnectTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                    guard !Task.isCancelled, let self, self.autoConnect else { return }
                    self.reconnectTask = nil
                    await self.reconnect()
                }
            }
            return
        }
        if event.name == "client.eventGap" {
            notice = "接続の続きを確認しています。"
            return
        }
        let payload = event.payload
        if event.name == "agent.identity.changed" || event.name == "config.changed" {
            if event.name == "config.changed" { agentNames = [:] }
            else if let id = payload["agentId"].stringValue { agentNames[id] = nil }
            if let target = selectedSession,
               event.name == "config.changed" || payload["agentId"].stringValue == target.agentID {
                agentIdentityRequest = UUID()
                agentIdentityTask?.cancel()
                agentIdentityTask = Task { [weak self] in await self?.refreshAgentName(for: target) }
            }
            return
        }
        if event.name == "chat", let session = store.matchingSession(key: payload["sessionKey"].stringValue ?? "", agentID: payload["agentId"].stringValue) {
            streamRevisions[session.id, default: 0] += 1
            store.applyChatEvent(payload)
            if ["final", "aborted", "error"].contains(payload["state"].stringValue ?? "") {
                pendingHistoryRefresh.insert(session.id); scheduleQuietRefresh()
            }
            scheduleSave(); return
        }
        if event.name == "agent", let session = store.matchingSession(key: payload["sessionKey"].stringValue ?? "", agentID: payload["agentId"].stringValue),
           let runID = payload["runId"].stringValue, store.activeRunIDs[session.id] == runID {
            let data = payload["data"]
            if payload["stream"].stringValue == "tool" {
                let name = data["name"].stringValue ?? ""
                let ending = ["end", "result", "error"].contains(data["phase"].stringValue ?? "")
                store.activities[session.id] = ending ? .working : (["web_search", "web_fetch", "browser"].contains(name) ? .searching : .working)
            }
            return
        }
        if event.name == "sessions.changed" || event.name == "chat.title" {
            let row = payload["session"] != .null ? payload["session"] : payload
            if let session = sessionFromRow(row) {
                sessionRevisions[session.id, default: 0] += 1
                store.upsertSession(session); scheduleSave()
            }
            else if event.name == "sessions.changed" { try? await refreshRoster() }
            if event.name == "sessions.changed", Self.isCollapsedMessageNotification(payload),
               let target = selectedSession, Self.notification(payload, row: row, targets: target) {
                // A read already in flight predates these messages; keep its stale snapshot from settling the refresh.
                streamRevisions[target.id, default: 0] += 1
                pendingHistoryRefresh.insert(target.id); scheduleQuietRefresh()
            }
            return
        }
        if event.name == "session.message", let target = selectedSession, payload["sessionKey"].stringValue == target.key {
            pendingHistoryRefresh.insert(target.id); scheduleQuietRefresh(); return
        }
        if ["exec.approval.requested", "plugin.approval.requested", "question.requested"].contains(event.name) { addPrompt(event.name, payload: payload); return }
        if ["exec.approval.resolved", "plugin.approval.resolved", "question.resolved"].contains(event.name), let id = payload["id"].stringValue {
            resolvedPromptIDs.insert(id)
            promptRecords.removeAll { $0.id == id || $0.id.hasPrefix(id + "|") }; questionRecords[id] = nil; questionAnswers[id] = nil
        }
    }

    /// Collapsed notifications cannot name individual messages; only a history read recovers them.
    nonisolated static func isCollapsedMessageNotification(_ payload: JSONValue) -> Bool {
        guard payload["phase"].stringValue == "message", let fields = payload.objectValue else { return false }
        return fields["message"] == nil && fields["messageId"] == nil && fields["messageSeq"] == nil
    }

    nonisolated static func notification(_ payload: JSONValue, row: JSONValue, targets target: ChatSession) -> Bool {
        guard let key = payload["sessionKey"].stringValue ?? payload["key"].stringValue ?? row["key"].stringValue ?? row["sessionKey"].stringValue,
              key == target.key else { return false }
        let agent = payload["agentId"].stringValue ?? row["agentId"].stringValue
        return agent == nil || agent == target.agentID
    }

    private func scheduleQuietRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, let target = self.selectedSession, self.pendingHistoryRefresh.contains(target.id) else { return }
            try? await self.refreshHistory(for: target)
        }
    }

    private func refreshPrompts() async {
        guard let service else { return }
        let generation = connectionGeneration
        for (method, event) in [("question.list", "question.requested"), ("exec.approval.list", "exec.approval.requested"), ("plugin.approval.list", "plugin.approval.requested")] {
            if let result = try? await service.request(method: method, params: .object([:])), generation == connectionGeneration {
                for record in result["questions"].arrayValue ?? result["approvals"].arrayValue ?? [] { addPrompt(event, payload: record) }
            }
        }
    }

    private func addPrompt(_ name: String, payload: JSONValue) {
        let request = payload["request"] != .null ? payload["request"] : payload
        guard let requestID = payload["id"].stringValue, !resolvedPromptIDs.contains(requestID), let session = store.matchingSession(key: request["sessionKey"].stringValue ?? payload["sessionKey"].stringValue ?? "", agentID: request["agentId"].stringValue ?? payload["agentId"].stringValue), payload["status"].stringValue == nil || payload["status"].stringValue == "pending" else { return }
        if name == "question.requested" {
            questionRecords[requestID] = payload
            for question in payload["questions"].arrayValue ?? [] {
                guard let questionID = question["questionId"].stringValue else { continue }
                let id = requestID + "|" + questionID
                let choices = question["options"].arrayValue?.compactMap { $0["label"].stringValue } ?? []
                let kind = question["isSecret"].boolValue == true ? "secret" : "question"
                let prompt = ApprovalPrompt(id: id, kind: kind, title: question["header"].stringValue ?? "質問", detail: question["question"].stringValue ?? "回答してください。", choices: choices)
                if !promptRecords.contains(where: { $0.id == id }) { promptRecords.append(prompt) }
                promptTargets[id] = session.id
            }
        } else {
            let plugin = name.hasPrefix("plugin")
            let choices = request["allowedDecisions"].arrayValue?.compactMap(\.stringValue) ?? ["allow-once", "deny"]
            let prompt = ApprovalPrompt(id: requestID, kind: plugin ? "plugin" : "exec", title: request["title"].stringValue ?? "実行の承認", detail: request["detail"].stringValue ?? request["description"].stringValue ?? request["command"].stringValue ?? "この操作を許可しますか？", choices: choices)
            if !promptRecords.contains(where: { $0.id == requestID }) { promptRecords.append(prompt) }
            promptTargets[requestID] = session.id
        }
        store.activities[session.id] = .waitingForApproval
    }

    func resolvePrompt(_ prompt: ApprovalPrompt, answer: String) async {
        guard let service else { return }
        let generation = connectionGeneration
        var resolvedRequestID: String?
        do {
            if prompt.kind == "question" || prompt.kind == "secret" {
                let parts = prompt.id.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let record = questionRecords[parts[0]] else { return }
                let question = record["questions"].arrayValue?.first { $0["questionId"].stringValue == parts[1] }
                let option = question?["options"].arrayValue?.first { $0["label"].stringValue == answer }
                let value = option?["value"].stringValue ?? answer
                questionAnswers[parts[0], default: [:]][parts[1]] = .array([.string(value)])
                let answers = questionAnswers[parts[0]] ?? [:]
                if answers.count == record["questions"].arrayValue?.count {
                    _ = try await service.request(method: "question.resolve", params: .object(["id": .string(parts[0]), "answers": .object(["answers": .object(answers)])]))
                    guard generation == connectionGeneration else { return }
                    questionAnswers[parts[0]] = nil; questionRecords[parts[0]] = nil
                    resolvedRequestID = parts[0]
                }
            } else {
                guard prompt.choices.contains(answer) else { return }
                _ = try await service.request(method: prompt.kind == "plugin" ? "plugin.approval.resolve" : "exec.approval.resolve", params: .object(["id": .string(prompt.id), "decision": .string(answer)]))
                resolvedRequestID = prompt.id
            }
            guard generation == connectionGeneration else { return }
            if let resolvedRequestID { resolvedPromptIDs.insert(resolvedRequestID) }
            promptRecords.removeAll { $0.id == prompt.id }
            if let target = promptTargets[prompt.id], store.activities[target] == .waitingForApproval { store.activities[target] = .working }
        } catch { if generation == connectionGeneration { errorMessage = error.localizedDescription } }
    }

    private func sessionFromRow(_ row: JSONValue) -> ChatSession? {
        guard let key = row["key"].stringValue ?? row["sessionKey"].stringValue else { return nil }
        let agentID = row["agentId"].stringValue ?? agentFromKey(key)
        guard let agentID else { return nil }
        let previous = store.sessions.first { $0.key == key && $0.agentID == agentID }
        let fallback = previous ?? ChatSession(key: key, agentID: agentID, title: "サイドチャット")
        return parseSession(row, fallback: fallback)
    }
    private func parseSession(_ row: JSONValue, fallback: ChatSession) -> ChatSession {
        var session = fallback
        session.key = row["key"].stringValue ?? row["sessionKey"].stringValue ?? session.key
        session.agentID = row["agentId"].stringValue ?? session.agentID
        session.sessionID = row["sessionId"].stringValue ?? session.sessionID
        if !session.isMain { session.title = row["label"].stringValue ?? row["displayName"].stringValue ?? row["title"].stringValue ?? session.title }
        if let model = row["model"].stringValue { session.modelID = qualifiedModel(id: model, provider: row["modelProvider"].stringValue) }
        if row.objectValue?["thinkingLevel"] != nil { session.thinkingLevel = row["thinkingLevel"].stringValue }
        return session
    }
    private func agentFromKey(_ key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 2)
        return parts.count == 3 && parts[0] == "agent" ? String(parts[1]) : nil
    }
    private func qualifiedModel(id: String, provider: String?) -> String {
        guard let provider, !id.hasPrefix(provider + "/") else { return id }
        return provider + "/" + id
    }
    private func targetParams(_ target: ChatSession, keyName: String = "sessionKey", extra: [String: JSONValue] = [:], includeSessionID: Bool = true) -> JSONValue {
        var body = extra
        body[keyName] = .string(target.key); body["agentId"] = .string(target.agentID)
        if includeSessionID, let id = target.sessionID { body["sessionId"] = .string(id) }
        return .object(body)
    }

    private func credentialKey(_ url: URL) -> String { "gateway:" + digest(url.absoluteString) }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func loadStore(namespace: String, transaction: UUID) async throws {
        let savedRevision = try await persistForSwitch(transaction)
        let key = digest(namespace)
        if persistenceNamespace == key { return }
        let incoming = try persistenceFactory(key)
        let loaded = try await incoming.load()
        try validateConnectionSwitch(transaction)
        if persistenceRevision != savedRevision { _ = try await persistForSwitch(transaction) }
        try validateConnectionSwitch(transaction)
        // Publish the owner and its state together, after all outgoing edits are durable.
        replaceStore(loaded, persistence: incoming, namespace: key)
    }
    private func replaceStore(_ state: ConversationStore, persistence: (any ConversationPersisting)?, namespace: String?) {
        saveTask?.cancel(); saveTask = nil
        self.persistence = persistence; persistenceNamespace = namespace; persistenceRevision = 0
        store = state
        store.retireTransientState()
        promptRecords = []; promptTargets = [:]; models = []; streamRevisions = [:]; sessionRevisions = [:]; pendingHistoryRefresh = []
    }
    private func persistForSwitch(_ transaction: UUID) async throws -> Int {
        while true {
            try validateConnectionSwitch(transaction)
            saveTask?.cancel(); persistenceRevision += 1
            let revision = persistenceRevision
            try await persistence?.save(store, revision: revision)
            try validateConnectionSwitch(transaction)
            if persistenceRevision == revision { return revision }
        }
    }
    private func scheduleSave() {
        persistenceRevision += 1
        saveTask?.cancel()
        let revision = persistenceRevision; let snapshot = store; let persistence = persistence
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                try await persistence?.save(snapshot, revision: revision)
            } catch is CancellationError { }
            catch { self?.errorMessage = "入力を端末に保存できませんでした。空き容量を確認してください。" }
        }
    }
    private func persistNow() async throws {
        saveTask?.cancel(); persistenceRevision += 1
        try await persistence?.save(store, revision: persistenceRevision)
    }
    private func fail(_ error: any Error) { connectionState = .failed(error.localizedDescription); errorMessage = error.localizedDescription }
}

actor ConversationPersistence: ConversationPersisting {
    private let url: URL
    private var newestRevision = -1
    init(namespace: String) throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = base.appendingPathComponent(namespace + ".json")
    }
    func load() throws -> ConversationStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConversationStore() }
        return try JSONDecoder().decode(ConversationStore.self, from: Data(contentsOf: url))
    }
    func save(_ state: ConversationStore, revision: Int) throws {
        guard revision > newestRevision else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        newestRevision = revision
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var resourceURL = url; try resourceURL.setResourceValues(values)
    }
}
