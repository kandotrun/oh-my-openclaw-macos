import Foundation
import Testing
@testable import OhMyOpenClawCore

private func record(_ id: String, _ role: String, run: String? = nil, at ms: Double? = nil, content: JSONValue = .array([]),
                    meta: [String: JSONValue] = [:], extra: [String: JSONValue] = [:]) -> JSONValue {
    var openclaw = meta.merging(["id": .string(id)]) { $1 }
    if let run { openclaw["runId"] = .string(run) }
    if let ms { openclaw["recordTimestampMs"] = .number(ms) }
    return .object(extra.merging(["role": .string(role), "content": content, "__openclaw": .object(openclaw)]) { $1 })
}
private func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }
private func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> JSONValue {
    .object(["type": .string("toolCall"), "id": .string(id), "name": .string(name), "arguments": .object(args)])
}
private func result(_ id: String, call callID: String, run: String, at ms: Double, output: String, isError: Bool = false,
                    details: [String: JSONValue] = [:], meta: [String: JSONValue] = [:]) -> JSONValue {
    record(id, "toolResult", run: run, at: ms, content: .array([text(output)]), meta: meta,
           extra: ["toolCallId": .string(callID), "isError": .bool(isError), "details": .object(details)])
}

/// OpenClaw's tool result records name their tool.
private func named(_ value: JSONValue, _ tool: String) -> JSONValue {
    guard case .object(var fields) = value else { return value }
    fields["toolName"] = .string(tool)
    return .object(fields)
}

/// A user prompt, an assistant turn that runs `swift test`, and its failing result.
private let basePage: [JSONValue] = [
    record("u1", "user", at: 1000, content: .array([text("直して")])),
    record("a1", "assistant", run: "r1", at: 3000, content: .array([text("確認します。"), call("c1", "exec", ["command": .string("swift test")])])),
    result("t1", call: "c1", run: "r1", at: 9000, output: "1 failure", details: ["exitCode": .number(1), "durationMs": .number(4210)]),
]

@Suite("Work log projection")
struct WorkLogProjectionTests {
    @Test func callsPairWithTheirResultsAndANonZeroExitFails() throws {
        let page = WorkLogProjection.project(messages: basePage, activity: .null, fallbackPrefix: "history")
        let entry = try #require(page.entries["a1"]?.first)
        #expect(entry.id == "a1|c1")
        #expect(entry.kind == .command)
        #expect(entry.summary == "swift test")
        #expect(entry.state == .failed)
        #expect(entry.exitCode == 1)
        #expect(entry.durationMs == 4210)
        #expect(entry.output == "1 failure")
        #expect(entry.resultRecordID == "t1")
        #expect(page.turnStarts == ["u1"])
        #expect(page.recordTimes["t1"] == Date(timeIntervalSince1970: 9))
    }

    @Test func anActivityItemSetsTheStateAndTitle() throws {
        let activity: JSONValue = .array([.object(["messageId": .string("t1"), "items": .array([.object([
            "itemId": .string("tool:c1"), "kind": .string("tool"), "toolCallId": .string("c1"), "title": .string("Exec"),
            "status": .string("blocked"), "approvalId": .string("ap1"),
        ])])])])
        let entry = try #require(WorkLogProjection.project(messages: basePage, activity: activity, fallbackPrefix: "history").entries["a1"]?.first)
        #expect(entry.state == .blocked)
        #expect(entry.title == "Exec")
    }

    @Test func aRecordWhoseActivityListOmitsTheToolIsRoutine() throws {
        let activity: JSONValue = .array([.object(["messageId": .string("a1"), "items": .array([])])])
        #expect(try #require(WorkLogProjection.project(messages: basePage, activity: activity, fallbackPrefix: "history").entries["a1"]?.first).isRoutine)
    }

    @Test func aSyntheticMissingResultIsUnknownNotFailed() throws {
        let page = [basePage[0], basePage[1], result("t1", call: "c1", run: "r1", at: 9000, output: "aborted", isError: true)]
        let activity: JSONValue = .array([.object(["messageId": .string("t1"), "items": .array([.object([
            "itemId": .string("tool:c1"), "kind": .string("tool"), "toolCallId": .string("c1"), "unpairedCall": .bool(true),
        ])])])])
        #expect(try #require(WorkLogProjection.project(messages: page, activity: activity, fallbackPrefix: "history").entries["a1"]?.first).state == .unknown)
    }

    @Test func aCallWithoutAResultIsUnknown() throws {
        let entry = try #require(WorkLogProjection.project(messages: Array(basePage.prefix(2)), activity: .null, fallbackPrefix: "history").entries["a1"]?.first)
        #expect(entry.state == .unknown)
        #expect(entry.resultRecordID == nil)
    }

    @Test func claudeCliResultsPairWithoutStartingATurn() throws {
        let page: [JSONValue] = [
            record("u1", "user", content: .array([text("一覧を見せて")])),
            record("a1", "assistant", run: "r1", content: .array([.object([
                "type": .string("tool_use"), "id": .string("toolu_1"), "name": .string("Bash"), "input": .object(["command": .string("ls")]),
            ])])),
            record("u2", "user", run: "r1", content: .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string("toolu_1"), "content": .string("ok"), "is_error": .bool(false),
            ])])),
        ]
        let projected = WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history")
        let entry = try #require(projected.entries["a1"]?.first)
        #expect(entry.kind == .command)
        #expect(entry.state == .completed)
        #expect(entry.output == "ok")
        #expect(projected.turnStarts == ["u1"])
    }

    @Test func stringArgumentsAreDecoded() throws {
        let page: [JSONValue] = [record("a1", "assistant", run: "r1", content: .array([.object([
            "type": .string("toolCall"), "id": .string("c1"), "name": .string("read"), "arguments": .string("{\"path\":\"a.swift\"}"),
        ])]))]
        #expect(try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["a1"]?.first).summary == "a.swift")
    }

    @Test func aResultWithoutItsCallIsAnchoredAtItself() throws {
        let page = [result("t9", call: "c9", run: "r1", at: 1, output: "done")]
        let entry = try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["t9"]?.first)
        #expect(entry.state == .completed)
        #expect(entry.anchorRecordID == "t9")
    }

    @Test func aTruncatedResultKeepsItsDiffWithoutAStat() throws {
        let page = [
            record("a1", "assistant", run: "r1", content: .array([call("c1", "edit", ["path": .string("a.swift")])])),
            result("t1", call: "c1", run: "r1", at: 2, output: "edited", details: ["diff": .string(" 1 a\n-2 b\n+2 c")], meta: ["truncated": .bool(true)]),
        ]
        let entry = try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["a1"]?.first)
        #expect(entry.outputTruncated)
        #expect(entry.diff?.lines.count == 3)
        #expect(entry.diff?.stat == nil)
    }

    @Test func anApplyPatchCallShowsItsEnvelope() throws {
        let envelope = "*** Begin Patch\n*** Update File: a.swift\n@@\n-old\n+new\n*** End Patch"
        let page = [
            record("a1", "assistant", run: "r1", content: .array([call("c1", "apply_patch", ["input": .string(envelope)])])),
            result("t1", call: "c1", run: "r1", at: 2, output: "Done"),
        ]
        let entry = try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["a1"]?.first)
        #expect(entry.kind == .edit)
        #expect(entry.summary == "a.swift")
        #expect(entry.diff?.stat == ToolDiff.Stat(added: 1, removed: 1))
    }

    @Test func runsThatFailedBeforeReplyingAreRecordedEvenThoughTheirRowIsHidden() {
        let page = [record("x", "custom", extra: ["customType": .string("run-failed-before-reply"), "openclawRunError": .object(["runId": .string("r2")])])]
        #expect(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").failedRuns == ["r2"])
    }

    @Test func steersAndHumanAddressedRowsStayInTheirTurn() {
        let page: [JSONValue] = [
            record("u1", "user", content: .array([text("作業して")])),
            record("u2", "user", content: .array([text("こっちもお願い")]), meta: ["steerTargetRunId": .string("r1")]),
            record("u3", "user", content: .array([text("@佐藤 見て")]), meta: ["humanAddressed": .bool(true)]),
            record("w1", "assistant", content: .array([text("定時の確認です")]), meta: ["turnBoundary": .bool(true)]),
            record("w2", "assistant", content: .array([text("続けます")]), meta: ["turnBoundary": .bool(true), "continuation": .object(["source": .string("exec")])]),
            record("f1", "assistant", content: .array([text("転送")]), extra: ["senderSession": .object(["sessionKey": .string("agent:b:main")])]),
        ]
        #expect(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").turnStarts == ["u1", "w1", "f1"])
    }

    @Test func aSubagentThatFailedToStartIsNotCountedAsStarted() throws {
        let page = [
            record("a1", "assistant", run: "r1", content: .array([call("c1", "sessions_spawn", ["task": .string("fix it")])])),
            result("t1", call: "c1", run: "r1", at: 2, output: "spawn failed", isError: true),
        ]
        #expect(try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["a1"]?.first).kind == .other)
    }

    @Test func nestedToolRecordsCarryTheirInnerCall() throws {
        let nested = record("n1", "custom", run: "r1", content: .array([
            call("c1", "read", ["path": .string("x.swift")]),
            .object(["type": .string("toolResult"), "role": .string("toolResult"), "id": .string("c1"), "content": .array([text("file")])]),
        ]), extra: ["customType": .string("openclaw.nested-tool.v1")])
        let entry = try #require(WorkLogProjection.project(messages: [nested], activity: .null, fallbackPrefix: "history").entries["n1"]?.first)
        #expect(entry.summary == "x.swift")
        #expect(entry.state == .completed)
        #expect(entry.output == "file")
    }

    @Test func aCallAndItsResultOnDifferentPagesBecomeOneEntry() throws {
        let older = WorkLogProjection.project(messages: [basePage[1]], activity: .null, fallbackPrefix: "older:0")
        let newer = WorkLogProjection.project(messages: [named(basePage[2], "exec")], activity: .null, fallbackPrefix: "history")
        let merged = newer.adding(older: older)
        let entry = try #require(merged.entries["a1"]?.first)
        #expect(entry.summary == "swift test")
        #expect(entry.output == "1 failure")
        #expect(entry.state == .failed)
        #expect(merged.entries["t1"]?.isEmpty ?? true)
    }

    @Test func aRefreshAfterLoadingOlderHistoryKeepsTheJoinedEntry() throws {
        let older = WorkLogProjection.project(messages: [basePage[1]], activity: .null, fallbackPrefix: "older:0")
        let newest = WorkLogProjection.project(messages: [named(basePage[2], "exec")], activity: .null, fallbackPrefix: "history")
        let refreshed = newest.adding(older: newest.adding(older: older))
        #expect(refreshed.entries["a1"]?.count == 1)
        #expect(refreshed.entries["a1"]?.first?.output == "1 failure")
        #expect(refreshed.entries["t1"]?.isEmpty ?? true)
    }

    @Test func aReportedOutcomeSurvivesJoiningAcrossPages() throws {
        let older = WorkLogProjection.project(messages: [basePage[1]], activity: .null, fallbackPrefix: "older:0")
        let activity: JSONValue = .array([.object(["messageId": .string("t1"), "items": .array([.object([
            "kind": .string("tool"), "toolCallId": .string("c1"), "status": .string("completed"),
        ])])])])
        let newer = WorkLogProjection.project(messages: [named(basePage[2], "exec")], activity: activity, fallbackPrefix: "history")
        #expect(try #require(newer.adding(older: older).entries["a1"]?.first).state == .completed)
    }

    @Test func aSubagentThatFailedToStartOnTheNextPageIsNotCountedAsStarted() throws {
        let spawn = record("a1", "assistant", run: "r1", content: .array([call("c1", "sessions_spawn", ["task": .string("fix it")])]))
        let older = WorkLogProjection.project(messages: [spawn], activity: .null, fallbackPrefix: "older:0")
        let failure = named(result("t1", call: "c1", run: "r1", at: 2, output: "spawn failed", isError: true), "sessions_spawn")
        let newer = WorkLogProjection.project(messages: [failure], activity: .null, fallbackPrefix: "history")
        #expect(try #require(newer.adding(older: older).entries["a1"]?.first).kind == .other)
    }

    @Test func commentaryIsNotAFinalReply() {
        // The Gateway splits commentary out of an assistant record into a row of its own with the same id.
        let commentary = record("a1", "assistant", run: "r1", at: 3000, content: .array([text("確認します。")]), extra: [
            "openclawStreamFallback": .object(["replacementText": .string("確認します。"), "source": .string("segment"), "itemId": .string("msg_1")]),
        ])
        let calls = record("a1", "assistant", run: "r1", at: 3000, content: .array([call("c1", "exec", ["command": .string("swift test")])]))
        let page = [basePage[0], commentary, calls, basePage[2], record("a2", "assistant", run: "r1", at: 28000, content: .array([text("直しました。")]))]
        #expect(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").finalReplies == ["a2"])
    }

    @Test func aCodexPatchShowsEveryFileItChanged() throws {
        let change = { (path: String) -> JSONValue in .object(["path": .string(path), "diff": .string("@@ -1 +1 @@\n-x\n+y")]) }
        let page = [record("a1", "assistant", run: "r1", content: .array([call("c1", "apply_patch", ["changes": .array([change("a.swift"), change("b.swift")])])]))]
        let diff = try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["a1"]?.first?.diff)
        #expect(diff.files == ["a.swift", "b.swift"])
        #expect(diff.stat == ToolDiff.Stat(added: 2, removed: 2))
    }

    @Test func aCodexPatchPastTheDiffBudgetStillCountsEveryFile() throws {
        // OpenClaw cuts the last diff that fits at a line and omits the rest, keeping each file's path and line counts.
        let stat = { (added: Int, removed: Int) -> JSONValue in .object(["added": .number(Double(added)), "removed": .number(Double(removed))]) }
        let changes: [JSONValue] = [
            .object(["path": .string("a.swift"), "diff": .string("@@ -1 +1 @@\n-x\n+y"), "stat": stat(1, 1)]),
            .object(["path": .string("b.swift"), "diff": .string("@@ -1,2 +1,2 @@\n-x\n+y\n"), "stat": stat(2, 2), "diffTruncated": .bool(true)]),
            .object(["path": .string("c.swift"), "stat": stat(5, 0), "diffTruncated": .bool(true)]),
        ]
        let page = [record("a1", "assistant", run: "r1", content: .array([call("c1", "apply_patch", ["changes": .array(changes)])]))]
        let diff = try #require(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries["a1"]?.first?.diff)
        #expect(diff.files == ["a.swift", "b.swift", "c.swift"])
        #expect(diff.stat == ToolDiff.Stat(added: 8, removed: 3))
        #expect(diff.isClipped)
    }

    @Test func finalRepliesAreAssistantTextWithoutCalls() {
        let page = basePage + [record("a2", "assistant", run: "r1", at: 28000, content: .array([text("直しました。")]))]
        #expect(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").finalReplies == ["a2"])
    }

    @Test func anchorsMatchTheTranscriptRows() {
        let page = basePage + [record("hidden", "system"), .object(["role": .string("assistant"), "content": .array([call("c2", "read", ["path": .string("b")])])])]
        let anchors = Set(WorkLogProjection.project(messages: page, activity: .null, fallbackPrefix: "history").entries.keys)
        let sources = Set(ConversationStore.parseMessages(page, fallbackPrefix: "history").compactMap(\.sourceID))
        #expect(anchors.isSubset(of: sources))
        #expect(anchors.contains("history:4"))
    }
}
