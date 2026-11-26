import Foundation

/// A single authenticated operator socket. Reconnect is an app-owned action so
/// pairing refusals and revoked credentials never produce a retry storm.
public actor GatewayClient: GatewayServing {
    public static let defaultScopes = ["operator.read", "operator.write", "operator.approvals", "operator.questions"]

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let deadline: Task<Void, Never>
        let isHandshake: Bool
    }
    private struct Challenge: Sendable { let nonce: String; let signedAt: Int64 }

    private let endpoint: URL
    private let credentials: GatewayCredentials
    private let identity: DeviceIdentity
    private let clientIdentity: GatewayClientIdentity
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var connectTask: Task<GatewayHello, any Error>?
    private var connectAttempt: UUID?
    private var challengeWaiter: CheckedContinuation<Challenge, any Error>?
    private var pending: [String: Pending] = [:]
    private var observers: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var epoch = UUID()
    private var hello: GatewayHello?
    private var admitted = false
    private var lastOuterSequence: Int?
    private var lastReceivedAt = ContinuousClock.now
    private var maxPayloadBytes = 25 * 1024 * 1024

    deinit { session.invalidateAndCancel() }

    public init(endpoint: URL, credentials: GatewayCredentials, identity: DeviceIdentity, clientIdentity: GatewayClientIdentity = GatewayClientIdentity()) {
        self.endpoint = endpoint; self.credentials = credentials; self.identity = identity; self.clientIdentity = clientIdentity
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: config, delegate: GatewayRedirectPolicy(), delegateQueue: nil)
    }

    public func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    public func connect() async throws -> GatewayHello {
        if let hello { return hello }
        if let connectTask { return try await connectTask.value }
        let attempt = UUID()
        let task = Task { try await self.establishConnection() }
        connectAttempt = attempt
        connectTask = task
        do {
            let result = try await task.value
            if connectAttempt == attempt { connectTask = nil; connectAttempt = nil }
            return result
        } catch {
            if connectAttempt == attempt { connectTask = nil; connectAttempt = nil }
            throw error
        }
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        connectAttempt = nil
        close(epoch: epoch, error: GatewayFailure(code: "DISCONNECTED", message: "接続を終了しました。"), notify: false)
    }

    public func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard hello != nil else { throw GatewayFailure(code: "NOT_CONNECTED", message: "Gateway への接続が完了していません。") }
        return try await sendRequest(method: method, params: params, epoch: epoch)
    }

    public func loadInboundMedia(_ reference: InboundMediaReference, session target: ChatSession) async throws -> Data {
        guard admitted, let hello, let token = hello.payload["auth"]["deviceToken"].stringValue ?? credentials.deviceToken, !token.isEmpty else {
            throw GatewayFailure(code: "MEDIA_PAIRING_REQUIRED", message: "画像を読み込むには、この端末を承認した Gateway に再接続してください。")
        }
        let currentEpoch = epoch
        let data = try await GatewayInboundMediaLoader.load(reference, session: target, endpoint: endpoint, deviceToken: token)
        try Task.checkCancellation()
        try requireCurrent(currentEpoch)
        guard admitted, self.hello != nil else { throw disconnectedError() }
        return data
    }

    private func establishConnection() async throws -> GatewayHello {
        try Task.checkCancellation()
        // Validate even when callers bypass the onboarding parser.
        let validatedEndpoint = try GatewayEndpoint.parse(endpoint.absoluteString)
        let connectionEpoch = UUID()
        epoch = connectionEpoch
        admitted = false
        maxPayloadBytes = 25 * 1024 * 1024
        lastOuterSequence = nil
        lastReceivedAt = .now
        let task = session.webSocketTask(with: validatedEndpoint)
        task.maximumMessageSize = maxPayloadBytes
        socket = task
        handshakeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.close(epoch: connectionEpoch, error: GatewayFailure(code: "CONNECT_TIMEOUT", message: "Gateway の接続確認がタイムアウトしました。URL とネットワークを確認してください。"), notify: false)
        }
        do {
            let challenge = try await withCheckedThrowingContinuation { continuation in
                challengeWaiter = continuation
                task.resume()
                receiveTask = Task { [weak self] in await self?.receiveLoop(task: task, epoch: connectionEpoch) }
            }
            try requireCurrent(connectionEpoch)
            let scopes = credentials.scopes ?? Self.defaultScopes
            var auth: [String: JSONValue] = [:]
            if let token = credentials.token ?? credentials.deviceToken { auth["token"] = .string(token) }
            else if let bootstrap = credentials.bootstrapToken { auth["bootstrapToken"] = .string(bootstrap) }
            if let password = credentials.password { auth["password"] = .string(password) }
            let params: JSONValue = .object([
                "minProtocol": .number(4), "maxProtocol": .number(4),
                "client": .object([
                    "id": .string("gateway-client"), "displayName": .string(clientIdentity.displayName),
                    "version": .string(clientIdentity.version), "platform": .string(clientIdentity.platform), "deviceFamily": .string(clientIdentity.deviceFamily),
                    "mode": .string("ui"), "instanceId": .string(identity.deviceID),
                ]),
                "role": .string("operator"), "scopes": .array(scopes.map(JSONValue.string)),
                "caps": .array(["tool-events", "session-scoped-events", "exec-approvals", "plugin-approvals", "approvals"].map(JSONValue.string)),
                "auth": .object(auth), "locale": .string(Locale.preferredLanguages.first ?? "ja-JP"),
                "device": try identity.deviceProof(nonce: challenge.nonce, signedAt: challenge.signedAt, credentials: credentials, scopes: scopes),
            ])
            let response = try await sendRequest(method: "connect", params: params, epoch: connectionEpoch)
            try requireCurrent(connectionEpoch)
            guard response["type"].stringValue == "hello-ok", response["protocol"].intValue == 4,
                  response["policy"].objectValue != nil, response["snapshot"].objectValue != nil else {
                throw GatewayFailure(code: "PROTOCOL_MISMATCH", message: "この Gateway の接続応答に対応していません。プロトコル v4 の対応ビルドを確認してください。")
            }
            let result = GatewayHello(payload: response)
            hello = result
            handshakeDeadline?.cancel(); handshakeDeadline = nil
            if let limit = response["policy"]["maxPayload"].intValue, limit > 0 {
                // Bound allocation even if a remote policy advertises an unreasonable value.
                maxPayloadBytes = min(limit, 64 * 1024 * 1024)
                task.maximumMessageSize = maxPayloadBytes
            }
            let tickMs = response["policy"]["tickIntervalMs"].numberValue ?? 15_000
            let interval = tickMs.isFinite && tickMs > 0 ? min(max(tickMs / 1000, 1), 120) : 15
            startWatchdog(epoch: connectionEpoch, interval: interval)
            return result
        } catch {
            close(epoch: connectionEpoch, error: error, notify: false)
            throw error
        }
    }

    private func sendRequest(method: String, params: JSONValue, epoch connectionEpoch: UUID) async throws -> JSONValue {
        try Task.checkCancellation()
        try requireCurrent(connectionEpoch)
        guard let socket else { throw disconnectedError() }
        let id = UUID().uuidString
        let frame: JSONValue = .object(["type": .string("req"), "id": .string(id), "method": .string(method), "params": params])
        let data = try JSONEncoder().encode(frame)
        guard data.count <= maxPayloadBytes else { throw GatewayFailure(code: "PAYLOAD_TOO_LARGE", message: "添付を含むメッセージ全体が Gateway の送信上限を超えています。添付を減らしてください。") }
        guard let text = String(data: data, encoding: .utf8) else { throw GatewayFailure(code: "ENCODING", message: "送信データを作成できませんでした。") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await self?.completeRequest(id: id, epoch: connectionEpoch, result: .failure(GatewayFailure(code: "REQUEST_TIMEOUT", message: "Gateway からの応答を確認できませんでした。送信状態を確認してから再試行してください。")))
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline, isHandshake: method == "connect")
                Task { [weak self] in
                    guard let self, await self.canSend(id: id, epoch: connectionEpoch) else { return }
                    do { try await socket.send(.string(text)) }
                    catch { await self.close(epoch: connectionEpoch, error: GatewayFailure(code: "CONNECTION_LOST", message: "Gateway との接続が切れました。送信結果を確認してから再試行してください。"), notify: true) }
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.completeRequest(id: id, epoch: connectionEpoch, result: .failure(CancellationError())) }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, epoch connectionEpoch: UUID) async {
        do {
            while !Task.isCancelled {
                let frame = try await task.receive()
                try requireCurrent(connectionEpoch)
                let data: Data
                switch frame {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw GatewayFailure(code: "INVALID_FRAME", message: "Gateway から未対応のデータを受信しました。")
                }
                guard data.count <= maxPayloadBytes else { throw GatewayFailure(code: "INVALID_FRAME", message: "Gateway の受信データが大きすぎます。") }
                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                lastReceivedAt = .now
                handleFrame(value, epoch: connectionEpoch)
            }
        } catch {
            guard connectionEpoch == epoch else { return }
            let failure = (error as? GatewayFailure) ?? GatewayFailure(code: "CONNECTION_LOST", message: "Gateway との接続が切れました。接続先とネットワークを確認してください。", details: .object(["networkCode": .number(Double((error as NSError).code))]))
            close(epoch: connectionEpoch, error: failure, notify: hello != nil)
        }
    }

    private func handleFrame(_ frame: JSONValue, epoch connectionEpoch: UUID) {
        switch frame["type"].stringValue {
        case "res":
            guard let id = frame["id"].stringValue else { return }
            if frame["ok"].boolValue == true {
                let response = frame["payload"]
                if pending[id]?.isHandshake == true, response["type"].stringValue == "hello-ok", response["protocol"].intValue == 4,
                   response["policy"].objectValue != nil, response["snapshot"].objectValue != nil {
                    // Events can follow hello in the same receive burst, before
                    // the suspended connect caller gets an actor turn.
                    admitted = true
                }
                completeRequest(id: id, epoch: connectionEpoch, result: .success(frame["payload"]))
            } else {
                let error = frame["error"]
                completeRequest(id: id, epoch: connectionEpoch, result: .failure(GatewayFailure(code: error["code"].stringValue ?? "GATEWAY_ERROR", message: error["message"].stringValue ?? "Gateway がリクエストを拒否しました。", details: error["details"])))
            }
        case "event":
            guard let name = frame["event"].stringValue else { return }
            let payload = frame["payload"]
            if name == "connect.challenge", let waiter = challengeWaiter {
                challengeWaiter = nil
                guard let nonce = payload["nonce"].stringValue, !nonce.isEmpty,
                      let timestamp = payload["ts"].numberValue, timestamp.isFinite,
                      timestamp >= 0, timestamp <= 9_007_199_254_740_991, timestamp.rounded() == timestamp else {
                    waiter.resume(throwing: GatewayFailure(code: "INVALID_CHALLENGE", message: "Gateway の認証チャレンジが不正です。接続先のバージョンを確認してください。"))
                    return
                }
                waiter.resume(returning: Challenge(nonce: nonce, signedAt: Int64(timestamp)))
                return
            }
            guard admitted else { return }
            let sequence = frame["seq"].intValue
            let gap = sequence.flatMap { next in lastOuterSequence.map { next > $0 + 1 } } ?? false
            if let sequence, let previous = lastOuterSequence, sequence <= previous { return }
            if let sequence { lastOuterSequence = sequence }
            let event = GatewayEvent(name: name, payload: payload, sequence: sequence)
            if gap {
                // A terminal frame settles its outcome before recovery replaces history.
                if name == "chat", ["final", "aborted", "error"].contains(payload["state"].stringValue ?? "") { _ = publish(event) }
                _ = publish(GatewayEvent(name: "client.eventGap"))
                close(epoch: connectionEpoch, error: GatewayFailure(code: "EVENT_GAP", message: "更新の一部を受信できませんでした。履歴の再取得が必要です。"), notify: true)
            } else if !publish(event) {
                close(epoch: connectionEpoch, error: GatewayFailure(code: "EVENT_OVERFLOW", message: "更新を再同期するために接続を終了しました。"), notify: true)
            }
        default: break
        }
    }

    private func startWatchdog(epoch connectionEpoch: UUID, interval: Double) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                if await self.checkLiveness(epoch: connectionEpoch, timeout: interval * 2) { return }
            }
        }
    }

    private func checkLiveness(epoch connectionEpoch: UUID, timeout: Double) -> Bool {
        guard connectionEpoch == epoch, hello != nil else { return true }
        if lastReceivedAt.duration(to: .now) > .seconds(timeout) {
            close(epoch: connectionEpoch, error: GatewayFailure(code: "TICK_TIMEOUT", message: "Gateway の応答が途絶えました。再接続して履歴を確認してください。"), notify: true)
            return true
        }
        return false
    }

    private func completeRequest(id: String, epoch connectionEpoch: UUID, result: Result<JSONValue, any Error>) {
        guard connectionEpoch == epoch, let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.continuation.resume(with: result)
    }

    private func close(epoch connectionEpoch: UUID, error: any Error, notify: Bool) {
        guard connectionEpoch == epoch else { return }
        epoch = UUID()
        hello = nil
        admitted = false
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        receiveTask?.cancel(); receiveTask = nil
        handshakeDeadline?.cancel(); handshakeDeadline = nil
        livenessTask?.cancel(); livenessTask = nil
        challengeWaiter?.resume(throwing: error); challengeWaiter = nil
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.deadline.cancel(); request.continuation.resume(throwing: error) }
        if notify {
            let code = (error as? GatewayFailure)?.code ?? "DISCONNECTED"
            _ = publish(GatewayEvent(name: "client.disconnected", payload: .object(["code": .string(code)])))
        }
    }

    @discardableResult private func publish(_ event: GatewayEvent) -> Bool {
        var retained = true
        for observer in observers.values { if case .dropped = observer.yield(event) { retained = false } }
        return retained
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func canSend(id: String, epoch expected: UUID) -> Bool { expected == epoch && pending[id] != nil }
    private func requireCurrent(_ expected: UUID) throws { if expected != epoch || socket == nil { throw disconnectedError() } }
    private func disconnectedError() -> GatewayFailure { GatewayFailure(code: "DISCONNECTED", message: "Gateway との接続が終了しました。") }
}

/// A setup URL is the complete trust destination. Do not follow an HTTP upgrade
/// redirect and then disclose its shared/bootstrap credential to another origin.
private final class GatewayRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
