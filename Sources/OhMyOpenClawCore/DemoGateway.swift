import Foundation

/// A deterministic, local-only Gateway for review and simulator use. No inference or network.
public actor DemoGateway: GatewayServing {
    private var continuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var sessions: [ChatSession] = [
        ChatSession(key: "agent:demo:main", agentID: "demo", sessionID: "demo-main", title: "メインチャット", isMain: true),
        ChatSession(key: "agent:demo:dashboard:weekend", agentID: "demo", sessionID: "demo-weekend", title: "週末の小さな旅"),
    ]
    private var histories: [String: [JSONValue]] = [
        "agent:demo:main": [
            .object(["id": .string("welcome-user"), "role": .string("user"), "content": .string("こんにちは。ここでは何ができる？")]),
            .object(["id": .string("welcome-assistant"), "role": .string("assistant"), "content": .string("こんにちは。ここは、あなたのエージェントと話すための場所です。\n\n話を続けたいときはこのまま、新しい話題は**サイドチャット**へ。\n\n- 写真やファイルを添える\n- モデルと思考レベルを選ぶ\n- 応答中の処理を止める\n\nこの会話はデモです。接続設定から自分の Gateway につなげられます。")]),
        ],
        "agent:demo:dashboard:weekend": [
            .object(["id": .string("weekend-user"), "role": .string("user"), "content": .string("週末、少し気分転換したい。")]),
            .object(["id": .string("weekend-assistant"), "role": .string("assistant"), "content": .string("遠くまで行かなくても、いつもと違う時間は作れます。\n\n朝の散歩と、気になっていた喫茶店。まずは半日だけ、予定を空けてみませんか。")]),
        ],
    ]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var runTargets: [String: String] = [:]
    private var runText: [String: String] = [:]
    private var accepted = Set<String>()
    private var outerSequence = 0
    private var connected = false

    public init() {}

    public func events() async -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let pair = AsyncStream<GatewayEvent>.makeStream()
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return pair.stream
    }
    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    public func connect() async throws -> GatewayHello {
        connected = true
        return GatewayHello(payload: .object([
            "type": .string("hello-ok"), "protocol": .number(4),
            "server": .object(["version": .string("local-demo")]),
            "snapshot": .object(["sessionDefaults": .object(["defaultAgentId": .string("demo"), "mainSessionKey": .string("agent:demo:main"), "mainKey": .string("main")])]),
            "policy": .object(["maxPayload": .number(25 * 1024 * 1024), "attachments": .object(["maxBytes": .number(19_464_192), "maxImageBytes": .number(6 * 1024 * 1024)])]),
            "features": .object(["methods": .array(["chat.send", "chat.abort", "chat.history", "sessions.create", "sessions.list", "sessions.subscribe", "sessions.messages.subscribe", "models.list", "sessions.patch"].map(JSONValue.string))]),
        ]))
    }

    public func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard connected else { throw GatewayFailure(code: "DISCONNECTED", message: "デモに接続していません。") }
        switch method {
        case "sessions.list": return list()
        case "sessions.subscribe": return .object(["subscribed": .bool(true), "list": list()])
        case "sessions.messages.subscribe": return .object(["subscribed": .bool(true)])
        case "sessions.messages.unsubscribe": return .object(["subscribed": .bool(false)])
        case "agent.identity.get": return .object(["agentId": .string("demo"), "name": .string("デモエージェント"), "nameSource": .string("agent")])
        case "models.list": return .object(["models": .array([
            .object(["id": .string("demo/balanced"), "provider": .string("demo"), "name": .string("Balanced"), "thinkingLevels": .array([.object(["id": .string("off"), "label": .string("オフ")]), .object(["id": .string("medium"), "label": .string("標準")]), .object(["id": .string("high"), "label": .string("深く考える")])])]),
            .object(["id": .string("demo/fast"), "provider": .string("demo"), "name": .string("Fast"), "thinkingLevels": .array([])]),
        ])])
        case "sessions.create":
            let key = "agent:demo:dashboard:" + UUID().uuidString
            let title = String((params["titleSource"].stringValue ?? "新しいサイドチャット").prefix(24))
            let session = ChatSession(key: key, agentID: "demo", sessionID: UUID().uuidString, title: title.isEmpty ? "新しいサイドチャット" : title, modelID: params["model"].stringValue, thinkingLevel: params["thinkingLevel"].stringValue)
            sessions.append(session); histories[key] = []
            emit("sessions.changed", .object(["session": row(session), "reason": .string("create")]))
            return .object(["key": .string(key), "sessionId": .string(session.sessionID!), "entry": row(session)])
        case "sessions.patch":
            guard let index = sessions.firstIndex(where: { $0.key == params["key"].stringValue }) else { throw GatewayFailure(code: "NOT_FOUND", message: "会話が見つかりません。") }
            if let label = params["label"].stringValue { sessions[index].title = label }
            if params.objectValue?["model"] != nil { sessions[index].modelID = params["model"].stringValue }
            if params.objectValue?["thinkingLevel"] != nil { sessions[index].thinkingLevel = params["thinkingLevel"].stringValue }
            emit("sessions.changed", .object(["session": row(sessions[index]), "reason": .string("patch")]))
            return .object(["key": .string(sessions[index].key), "entry": row(sessions[index])])
        case "chat.history":
            let key = params["sessionKey"].stringValue ?? ""
            let session = sessions.first { $0.key == key }
            var value: [String: JSONValue] = ["messages": .array(histories[key] ?? []), "sessionId": session?.sessionID.map(JSONValue.string) ?? .null]
            if let runID = runTargets.first(where: { $0.value == key })?.key { value["inFlightRun"] = .object(["runId": .string(runID), "text": .string(runText[runID] ?? "")]) }
            value["inputReceipts"] = .array((params["inputRunIds"].arrayValue ?? []).compactMap { run -> JSONValue? in
                guard let id = run.stringValue, accepted.contains(id) else { return nil }
                return .object(["runId": .string(id), "state": .string("consumed"), "consumedByEventId": .string(id + ":user")])
            })
            return .object(value)
        case "chat.send":
            guard let key = params["sessionKey"].stringValue, let id = params["idempotencyKey"].stringValue else { throw GatewayFailure(code: "INVALID_REQUEST", message: "送信先がありません。") }
            if accepted.contains(id) { return .object(["runId": .string(id), "status": .string("ok")]) }
            accepted.insert(id)
            var user: [String: JSONValue] = ["id": .string(id + ":user"), "role": .string("user"), "content": .string(params["message"].stringValue ?? ""), "runId": .string(id)]
            if let attachmentArray = params["attachments"].arrayValue, !attachmentArray.isEmpty {
                user["content"] = .array([.object(["type": .string("text"), "text": .string(params["message"].stringValue ?? "")])] + attachmentArray.map { attachment in
                    .object(["type": attachment["type"], "fileName": attachment["fileName"], "mimeType": attachment["mimeType"], "data": attachment["content"]])
                })
            }
            histories[key, default: []].append(.object(user))
            runTargets[id] = key; runText[id] = ""
            emit("chat", chat(key: key, runID: id, seq: 1, state: "status", extra: ["phase": .string("preparing_context")]))
            tasks[id] = Task { [weak self] in await self?.respond(key: key, runID: id, input: params["message"].stringValue ?? "", attachments: params["attachments"].arrayValue?.count ?? 0) }
            return .object(["runId": .string(id), "status": .string("started"), "messageSeq": .number(Double(histories[key]?.count ?? 1))])
        case "chat.abort":
            guard let id = params["runId"].stringValue, let key = runTargets[id] else { return .object(["aborted": .bool(false)]) }
            tasks[id]?.cancel(); tasks[id] = nil
            let text = runText[id] ?? ""
            if !text.isEmpty { histories[key, default: []].append(.object(["id": .string(id + ":assistant"), "role": .string("assistant"), "content": .string(text)])) }
            emit("chat", chat(key: key, runID: id, seq: 10_000, state: "aborted"))
            runTargets[id] = nil; runText[id] = nil
            return .object(["aborted": .bool(true), "runIds": .array([.string(id)])])
        case "question.list": return .object(["questions": .array([])])
        case "exec.approval.list", "plugin.approval.list": return .object(["approvals": .array([])])
        default: throw GatewayFailure(code: "METHOD_NOT_FOUND", message: "この操作はデモでは使えません。")
        }
    }

    public func disconnect() async {
        connected = false
        for task in tasks.values { task.cancel() }
        tasks = [:]; runTargets = [:]; runText = [:]
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    private func list() -> JSONValue { .object(["sessions": .array(sessions.map(row))]) }
    private func row(_ session: ChatSession) -> JSONValue {
        var value: [String: JSONValue] = ["key": .string(session.key), "agentId": .string(session.agentID), "sessionId": .string(session.sessionID ?? ""), "displayName": .string(session.title)]
        if let model = session.modelID { value["model"] = .string(model) }
        if let thinking = session.thinkingLevel { value["thinkingLevel"] = .string(thinking) }
        return .object(value)
    }
    private func emit(_ name: String, _ payload: JSONValue) {
        outerSequence += 1
        for continuation in continuations.values { continuation.yield(GatewayEvent(name: name, payload: payload, sequence: outerSequence)) }
    }
    private func chat(key: String, runID: String, seq: Int, state: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["sessionKey": .string(key), "agentId": .string("demo"), "runId": .string(runID), "seq": .number(Double(seq)), "state": .string(state)], uniquingKeysWith: { _, new in new }))
    }
    private func respond(key: String, runID: String, input: String, attachments: Int) async {
        do {
            try await Task.sleep(for: .milliseconds(500))
            emit("agent", .object(["sessionKey": .string(key), "agentId": .string("demo"), "runId": .string(runID), "stream": .string("tool"), "data": .object(["name": .string("web_search"), "phase": .string("start")])]))
            try await Task.sleep(for: .milliseconds(800))
            emit("agent", .object(["sessionKey": .string(key), "agentId": .string("demo"), "runId": .string(runID), "stream": .string("tool"), "data": .object(["name": .string("web_search"), "phase": .string("end")])]))
            let answer = attachments > 0 ? "\(attachments)件のファイルを受け取りました。\n\nこれは**デモの応答**です。実際の Gateway に接続すると、添付したファイルとメッセージをエージェントに渡します。" : "「\(String(input.prefix(80)))」について、一緒に考えましょう。\n\nこの画面では、応答が少しずつ届きます。別の話題は左上のメニューから**新しいサイドチャット**へ。\n\n```swift\nlet conversation = \"あなたのペースで\"\nprint(conversation)\n```\n\nこれは操作を試すためのデモです。実際の回答には自分の Gateway を接続してください。"
            var sequence = 2
            let chunks = answer.chunks(ofCount: 8)
            for chunk in chunks {
                try Task.checkCancellation()
                runText[runID, default: ""] += chunk
                emit("chat", chat(key: key, runID: runID, seq: sequence, state: "delta", extra: ["deltaText": .string(chunk)]))
                sequence += 1
                try await Task.sleep(for: .milliseconds(80))
            }
            histories[key, default: []].append(.object(["id": .string(runID + ":assistant"), "role": .string("assistant"), "content": .string(answer)]))
            emit("chat", chat(key: key, runID: runID, seq: sequence, state: "final"))
            runTargets[runID] = nil; runText[runID] = nil; tasks[runID] = nil
        } catch { /* Cancellation is settled by abort/disconnect. */ }
    }
}

private extension String {
    func chunks(ofCount count: Int) -> [String] {
        var result: [String] = []; var cursor = startIndex
        while cursor < endIndex {
            let next = index(cursor, offsetBy: count, limitedBy: endIndex) ?? endIndex
            result.append(String(self[cursor..<next])); cursor = next
        }
        return result
    }
}
