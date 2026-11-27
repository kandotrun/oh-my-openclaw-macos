import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

private func record(_ id: String, _ role: String, run: String? = nil, at seconds: Double, content: [JSONValue],
                    meta: [String: JSONValue] = [:], extra: [String: JSONValue] = [:]) -> JSONValue {
    var openclaw = meta.merging(["id": .string(id), "recordTimestampMs": .number(seconds * 1000)]) { $1 }
    if let run { openclaw["runId"] = .string(run) }
    return .object(extra.merging(["role": .string(role), "content": .array(content), "__openclaw": .object(openclaw)]) { $1 })
}
private func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }
private func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> JSONValue {
    .object(["type": .string("toolCall"), "id": .string(id), "name": .string(name), "arguments": .object(args)])
}
private func result(_ id: String, call callID: String, at seconds: Double) -> JSONValue {
    record(id, "toolResult", run: "r1", at: seconds, content: [text("ok")], extra: ["toolCallId": .string(callID)])
}
private func failure(_ id: String, call callID: String, at seconds: Double) -> JSONValue {
    record(id, "toolResult", run: "r1", at: seconds, content: [text("1 failure")], extra: ["toolCallId": .string(callID), "isError": .bool(true)])
}
private let image: JSONValue = .object(["type": .string("image"), "url": .string("/api/chat/media/outgoing/a/1/full"), "mimeType": .string("image/png")])

/// A prompt, a reply that runs `swift test`, a silent read, and the final answer 27 seconds after the prompt.
private let settled: [JSONValue] = [
    record("u1", "user", at: 1, content: [text("直して")]),
    record("a1", "assistant", run: "r1", at: 3, content: [text("確認します。"), call("c1", "exec", ["command": .string("swift test")])]),
    result("t1", call: "c1", at: 9),
    record("a2", "assistant", run: "r1", at: 10, content: [call("c2", "read", ["path": .string("a.swift")])]),
    result("t2", call: "c2", at: 11),
    record("a3", "assistant", run: "r1", at: 28, content: [text("直しました。")]),
]

private func build(_ records: [JSONValue], active: String? = nil, failed: Set<String> = [], viewer: ViewerIdentity = .profile("p1")) -> [TimelineItem] {
    var page = WorkLogProjection.project(messages: records, activity: .null, fallbackPrefix: "history")
    page.failedRuns.formUnion(failed)
    return Timeline.build(TimelineInput(rows: ConversationStore.parseMessages(records, fallbackPrefix: "history"), page: page,
                                        activeRunID: active, viewer: viewer))
}

private func shape(_ items: [TimelineItem]) -> [String] {
    items.map { item in
        switch item {
        case .message(let message, _): "message " + message.text
        case .entry(let entry, _): "entry " + entry.toolCallID
        case .group(let group): "group " + group.entries.map(\.toolCallID).joined(separator: ",")
        case .fold(let fold): "fold " + fold.label + " [" + shape(fold.items).joined(separator: "; ") + "]"
        }
    }
}

@Suite("Timeline")
struct TimelineTests {
    @Test func aSettledTurnFoldsItsWorkUnderThePrompt() {
        #expect(shape(build(settled)) == [
            "message 直して",
            "fold 27秒作業しました [message 確認します。; group c1,c2]",
            "message 直しました。",
        ])
    }

    @Test func theFoldGroupSaysWhatHappened() throws {
        guard case .fold(let fold) = build(settled)[1], case .group(let group) = fold.items[1] else { Issue.record("no fold group"); return }
        #expect(group.sentence == "コマンドを1回実行し、1件のファイルを読み込みました")
    }

    @Test func aRunningTurnShowsItsWorkInline() {
        #expect(shape(build(settled, active: "r1")) == ["message 直して", "message 確認します。", "group c1,c2", "message 直しました。"])
    }

    @Test func aFailedRunListsEachCall() {
        #expect(shape(build(settled, failed: ["r1"])) == ["message 直して", "message 確認します。", "entry c1", "entry c2", "message 直しました。"])
    }

    @Test func aTurnWithoutToolsLooksAsBefore() {
        let records = [record("u1", "user", at: 1, content: [text("こんにちは")]), record("a1", "assistant", run: "r1", at: 2, content: [text("こんにちは。")])]
        #expect(shape(build(records)) == ["message こんにちは", "message こんにちは。"])
    }

    @Test func peopleAndImagesStayOutOfTheFold() {
        var records = settled
        records.insert(record("s1", "user", at: 12, content: [text("ついでにこれも")], meta: ["steerTargetRunId": .string("r1")]), at: 5)
        records.insert(record("m1", "assistant", run: "r1", at: 13, content: [.object(["type": .string("image"), "url": .string("/api/chat/media/outgoing/a/1/full"),
                                                                                    "mimeType": .string("image/png")])]), at: 6)
        let items = shape(build(records))
        #expect(items.first == "message 直して")
        #expect(items.contains("message ついでにこれも"))
        #expect(items.last == "message 直しました。")
        #expect(items.count == 5)
    }

    @Test func aTeammatesPromptStartsTheirTurnOnTheLeft() {
        var records = settled
        records[0] = record("u1", "user", at: 1, content: [text("直して")], meta: [
            "senderId": .string("p2"), "senderName": .string("佐藤 花子"), "senderIdentity": .object(["type": .string("profile"), "id": .string("p2")]),
        ])
        guard case .message(_, let attribution) = build(records).first else { Issue.record("no prompt"); return }
        guard case .peer(let chrome) = attribution else { Issue.record("not a peer"); return }
        #expect(chrome.name == "佐藤 花子")
    }

    @Test func aHiddenWakeStartsItsOwnTurn() {
        let records = [
            record("u1", "user", at: 1, content: [text("直して")]),
            record("a1", "assistant", run: "r1", at: 2, content: [text("完了しました")]),
            record("w1", "assistant", run: "r2", at: 100, content: [call("c1", "exec", ["command": .string("uptime")])], meta: ["turnBoundary": .bool(true)]),
            record("t1", "toolResult", run: "r2", at: 101, content: [text("ok")], extra: ["toolCallId": .string("c1")]),
            record("w2", "assistant", run: "r2", at: 102, content: [text("定期確認は問題ありません")]),
        ]
        #expect(shape(build(records)) == ["message 直して", "message 完了しました", "fold 作業しました [entry c1]", "message 定期確認は問題ありません"])
    }

    @Test func aFailureThatEndsAfterTheAnswerStaysInView() {
        let records = [
            record("u1", "user", at: 1, content: [text("直して")]),
            record("a1", "assistant", run: "r1", at: 2, content: [text("確認します。"), call("c1", "exec", ["command": .string("swift test")])]),
            record("a2", "assistant", run: "r1", at: 3, content: [text("直しました。")]),
            failure("t1", call: "c1", at: 4),
        ]
        #expect(shape(build(records)) == ["message 直して", "message 確認します。", "message 直しました。", "entry c1"])
    }

    @Test func aFailureAfterAnImageOnlyAnswerStaysInView() {
        let records = [
            record("u1", "user", at: 1, content: [text("描いて")]),
            record("a1", "assistant", run: "r1", at: 2, content: [text("描きます。"), call("c1", "exec", ["command": .string("render")])]),
            record("m1", "assistant", run: "r1", at: 3, content: [image]),
            failure("t1", call: "c1", at: 4),
        ]
        #expect(shape(build(records)) == ["message 描いて", "message 描きます。", "message ", "entry c1"])
    }

    @Test func lateFailuresWithALateSuccessBetweenThemStaySeparate() {
        let records = [
            record("u1", "user", at: 1, content: [text("直して")]),
            record("a1", "assistant", run: "r1", at: 2, content: [text("確認します。"), call("c1", "exec", ["command": .string("swift test")]),
                                                             call("c2", "read", ["path": .string("a.swift")]), call("c3", "exec", ["command": .string("swift build")])]),
            record("a2", "assistant", run: "r1", at: 3, content: [text("直しました。")]),
            failure("t1", call: "c1", at: 4),
            result("t2", call: "c2", at: 5),
            failure("t3", call: "c3", at: 6),
        ]
        #expect(shape(build(records)) == ["message 直して", "fold 5秒作業しました [message 確認します。; entry c2]", "message 直しました。", "entry c1", "entry c3"])
    }

    @Test func commentaryBeforeACallIsNotTheAnswer() {
        let records = Array(settled.prefix(3))
        #expect(shape(build(records)) == ["message 直して", "fold 8秒作業しました [message 確認します。; entry c1]"])
    }

    @Test func peopleBetweenCallsKeepThemInSeparateGroups() {
        var records = settled
        records.insert(record("s1", "user", at: 9.5, content: [text("ついでに")], meta: ["steerTargetRunId": .string("r1")]), at: 3)
        #expect(shape(build(records)) == ["message 直して", "fold 27秒作業しました [message 確認します。; entry c1; entry c2]", "message ついでに", "message 直しました。"])
    }

    @Test func withoutAWorkLogTheTranscriptIsUnchanged() {
        let rows = ConversationStore.parseMessages(settled, fallbackPrefix: "history")
        let items = Timeline.build(TimelineInput(rows: rows, page: nil, activeRunID: nil, viewer: .unresolved))
        #expect(shape(items) == ["message 直して", "message 確認します。", "message 直しました。"])
    }
}
