import Foundation

/// A deterministic, local-only Gateway for review and simulator use. No inference or network.
public actor DemoGateway: GatewayServing {
    private var continuations: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var sessions: [ChatSession] = [
        ChatSession(key: "agent:demo:main", agentID: "demo", sessionID: "demo-main", title: "メインチャット", isMain: true),
        ChatSession(key: "agent:demo:dashboard:team", agentID: "demo", sessionID: "demo-team", title: "チームの作業"),
        ChatSession(key: "agent:demo:dashboard:weekend", agentID: "demo", sessionID: "demo-weekend", title: "週末の小さな旅"),
    ]
    private var histories: [String: [JSONValue]] = [
        "agent:demo:main": [
            DemoGateway.userRow("welcome-user", "こんにちは。ここでは何ができる？", sender: DemoGateway.you),
            .object(["id": .string("welcome-assistant"), "role": .string("assistant"), "content": .string("こんにちは。ここは、あなたのエージェントと話すための場所です。\n\n話を続けたいときはこのまま、新しい話題は**サイドチャット**へ。\n\n- 写真やファイルを添える\n- モデルと思考レベルを選ぶ\n- 応答中の処理を止める\n\nこの会話はデモです。接続設定から自分の Gateway につなげられます。")]),
        ],
        // A shared thread: two teammates and the viewer.
        "agent:demo:dashboard:team": [
            DemoGateway.userRow("team-hana", "ログイン画面の UI テストが時々落ちます。原因を見てもらえますか？", sender: [
                "senderId": .string("demo-hana"), "senderName": .string("佐藤 花子"), "recordTimestampMs": .number(1_795_700_001_000),
                "senderIdentity": .object(["type": .string("profile"), "id": .string("demo-hana")]),
            ]),
            DemoGateway.assistantRow("team-look", run: "team-run", [
                DemoGateway.text("見てみます。"),
                .object(["type": .string("toolCall"), "id": .string("team-c1"), "name": .string("exec"),
                         "arguments": .object(["command": .string("swift test --filter LoginFlowTests")])]),
            ], at: .number(1_795_700_003_000)),
            DemoGateway.resultRow("team-t1", run: "team-run", callID: "team-c1", output: "LoginFlowTests.testSignIn failed: timed out after 2.0 seconds",
                                  details: ["exitCode": .number(1), "durationMs": .number(6200)], at: .number(1_795_700_009_000)),
            DemoGateway.assistantRow("team-edit", run: "team-run", [
                .object(["type": .string("toolCall"), "id": .string("team-c2"), "name": .string("edit"),
                         "arguments": .object(["path": .string("UITests/LoginFlowTests.swift")])]),
            ], at: .number(1_795_700_010_000)),
            DemoGateway.resultRow("team-t2", run: "team-run", callID: "team-c2", output: "Edited UITests/LoginFlowTests.swift",
                                  details: ["diff": .string(" 41 let field = app.textFields[\"email\"]\n-42 XCTAssertTrue(field.waitForExistence(timeout: 2))\n+42 XCTAssertTrue(field.waitForExistence(timeout: 5))")],
                                  at: .number(1_795_700_011_000)),
            DemoGateway.assistantRow("team-answer", run: "team-run", [DemoGateway.text("`LoginFlowTests` が、画面の切り替わりを 2 秒しか待っていませんでした。待ち時間を 5 秒にすると、20 回続けて通りました。")],
                                     at: .number(1_795_700_031_000)),
            DemoGateway.userRow("team-taro", "CI でも同じ症状が出ていました。", sender: [
                "senderId": .string("U024BE7LH"), "senderName": .string("田中 太郎"),
                "senderIdentity": .object(["type": .string("observation"), "id": .string("U024BE7LH"), "pluginId": .string("slack"),
                                           "accountId": .null, "senderKind": .string("human")]),
            ]),
            DemoGateway.userRow("team-you", "ありがとう。その修正で PR を作っておいて。", sender: DemoGateway.you),
            .object(["id": .string("team-done"), "role": .string("assistant"), "content": .string("PR を作りました。CI の結果が出たらお知らせします。")]),
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

    /// The demo viewer: named by `hello-ok` presence and stamped on every send, as a profile connection would be.
    private static let you: [String: JSONValue] = [
        "senderId": .string("demo-you"), "senderName": .string("あなた"),
        "senderIdentity": .object(["type": .string("profile"), "id": .string("demo-you")]),
    ]

    private static func userRow(_ id: String, _ text: String, sender: [String: JSONValue], extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["id": .string(id), "role": .string("user"), "content": .string(text),
                               "__openclaw": .object(sender.merging(["id": .string(id)]) { $1 })]) { $1 })
    }

    /// The demo run's tool calls: a passing test, a read, and an edit with a numbered diff.
    private static let steps: [(name: String, args: [String: JSONValue], output: String, details: [String: JSONValue])] = [
        ("exec", ["command": .string("swift test --filter Greeting")], "Test Suite 'Greeting' passed.\nExecuted 3 tests, with 0 failures",
         ["exitCode": .number(0), "durationMs": .number(812)]),
        ("read", ["path": .string("Sources/Greeting.swift")], "let greeting = \"Hello\"", [:]),
        ("edit", ["path": .string("Sources/Greeting.swift")], "Edited Sources/Greeting.swift",
         ["diff": .string(" 1 import Foundation\n-2 let greeting = \"Hello\"\n+2 let greeting = \"こんにちは\"")]),
    ]

    private static func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }

    private static func now() -> JSONValue { .number((Date().timeIntervalSince1970 * 1000).rounded()) }

    private static func assistantRow(_ id: String, run: String?, _ content: [JSONValue], at time: JSONValue? = nil) -> JSONValue {
        var metadata: [String: JSONValue] = ["id": .string(id), "recordTimestampMs": time ?? now()]
        if let run { metadata["runId"] = .string(run) }
        return .object(["role": .string("assistant"), "content": .array(content), "__openclaw": .object(metadata)])
    }

    /// Adds a tool call to the newest assistant record, as the agent loop writes it.
    private static func appendCall(_ records: inout [JSONValue], callID: String, name: String, args: [String: JSONValue]) {
        guard var last = records.last?.objectValue, var content = last["content"]?.arrayValue else { return }
        content.append(.object(["type": .string("toolCall"), "id": .string(callID), "name": .string(name), "arguments": .object(args)]))
        last["content"] = .array(content)
        records[records.count - 1] = .object(last)
    }

    private static func resultRow(_ id: String, run: String?, callID: String, output: String, details: [String: JSONValue], at time: JSONValue? = nil) -> JSONValue {
        var metadata: [String: JSONValue] = ["id": .string(id), "recordTimestampMs": time ?? now()]
        if let run { metadata["runId"] = .string(run) }
        return .object(["role": .string("toolResult"), "toolCallId": .string(callID), "content": .array([text(output)]),
                        "details": .object(details), "__openclaw": .object(metadata)])
    }

    private func emitTool(_ phase: String, key: String, runID: String, callID: String, name: String, _ data: [String: JSONValue]) {
        emit("agent", .object(["sessionKey": .string(key), "agentId": .string("demo"), "runId": .string(runID), "stream": .string("tool"),
                               "data": .object(data.merging(["phase": .string(phase), "name": .string(name), "toolCallId": .string(callID)]) { $1 })]))
    }

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
            "server": .object(["version": .string("local-demo"), "connId": .string("demo-connection")]),
            "snapshot": .object([
                "sessionDefaults": .object(["defaultAgentId": .string("demo"), "mainSessionKey": .string("agent:demo:main"), "mainKey": .string("main")]),
                "presence": .array([.object(["connectionId": .string("demo-connection"), "ts": .number(0), "user": .object([
                    "id": .string("demo-you"), "name": .string("あなた"),
                    "identity": .object(["type": .string("profile"), "id": .string("demo-you")]),
                ])])]),
            ]),
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
            var user = DemoGateway.userRow(id + ":user", params["message"].stringValue ?? "", sender: DemoGateway.you.merging(["recordTimestampMs": DemoGateway.now()]) { $1 },
                                           extra: ["runId": .string(id)]).objectValue ?? [:]
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
            try await Task.sleep(for: .milliseconds(400))
            // The agent runs a test, reads a file, and edits it. History keeps each call and result for the work log.
            histories[key, default: []].append(DemoGateway.assistantRow(runID + ":a1", run: runID, [DemoGateway.text("確認します。")]))
            for (index, step) in DemoGateway.steps.enumerated() {
                let callID = runID + ":c\(index + 1)"
                emitTool("start", key: key, runID: runID, callID: callID, name: step.name, ["args": .object(step.args)])
                if index > 0 { histories[key, default: []].append(DemoGateway.assistantRow(runID + ":a\(index + 1)", run: runID, [])) }
                DemoGateway.appendCall(&histories[key, default: []], callID: callID, name: step.name, args: step.args)
                try await Task.sleep(for: .milliseconds(350))
                emitTool("result", key: key, runID: runID, callID: callID, name: step.name, ["isError": .bool(false)])
                histories[key, default: []].append(DemoGateway.resultRow(runID + ":t\(index + 1)", run: runID, callID: callID, output: step.output, details: step.details))
            }
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
            histories[key, default: []].append(DemoGateway.assistantRow(runID + ":assistant", run: runID, [DemoGateway.text(answer)]))
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
