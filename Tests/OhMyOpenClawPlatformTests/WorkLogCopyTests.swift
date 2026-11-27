import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

private func entry(_ name: String, _ kind: WorkLogKind, path: String = "", state: WorkLogState = .completed, exitCode: Int? = nil,
                   durationMs: Int? = nil) -> WorkLogEntry {
    var value = WorkLogEntry(id: name + path, toolCallID: name, runID: "r1", name: name, kind: kind, state: state, summary: path, anchorRecordID: "a")
    value.exitCode = exitCode; value.durationMs = durationMs
    return value
}

@Suite("Work log copy")
struct WorkLogCopyTests {
    @Test(arguments: [
        (-5, "0ミリ秒"), (0, "1ミリ秒"), (850, "850ミリ秒"), (3000, "3秒"), (3400, "3.4秒"), (3450, "3.5秒"), (9960, "10秒"),
        (59000, "59秒"), (59500, "1分0秒"), (736_000, "12分16秒"), (3_600_000, "1時間"), (3_660_000, "1時間1分0秒"), (3_605_000, "1時間5秒"),
    ])
    func durationsReadLikeT3InJapanese(milliseconds: Int, expected: String) {
        #expect(WorkDuration.format(milliseconds: milliseconds) == expected)
    }

    @Test func summarySentenceKeepsTheTwoMostTellingKinds() {
        let commands = (0..<3).map { entry("exec\($0)", .command) }
        let reads = (0..<4).map { entry("read\($0)", .read, path: "r\($0)") }
        #expect(WorkLogCopy.sentence(commands + reads) == "コマンドを3回実行し、4件のファイルを読み込みました")
        #expect(WorkLogCopy.sentence(commands + [entry("edit", .edit, path: "a"), entry("write", .write, path: "b")] + reads)
            == "コマンドを3回実行し、2件のファイルを変更し、ほかに4件の操作を行いました")
        #expect(WorkLogCopy.sentence(reads + commands) == "4件のファイルを読み込み、コマンドを3回実行しました")
        #expect(WorkLogCopy.sentence([entry("edit", .edit, path: "a"), entry("edit2", .edit, path: "a")]) == "1件のファイルを変更しました")
        #expect(WorkLogCopy.sentence([entry("m1", .other), entry("m2", .other)]) == "ツールを2回使用しました")
        #expect(WorkLogCopy.sentence([entry("grep", .search), entry("web_search", .search), entry("web_fetch", .fetch), entry("mcp", .other)])
            == "2回検索し、1件のページを取得し、ほかに1件の操作を行いました")
    }

    @Test func aPatchCountsEveryFileItChanges() {
        var patch = entry("apply_patch", .edit, path: "a.swift")
        patch.diff = ToolDiff.patchEnvelope("*** Begin Patch\n*** Update File: a.swift\n@@\n-x\n+y\n*** Update File: b.swift\n@@\n-x\n+y\n*** End Patch")
        #expect(WorkLogCopy.sentence([patch]) == "2件のファイルを変更しました")
    }

    @Test func entryLabelsNameWhatWasTouched() {
        #expect(WorkLogCopy.label(entry("exec", .command, path: "swift test")) == "swift test")
        #expect(WorkLogCopy.label(entry("read", .read, path: "a.swift")) == "読み込み a.swift")
        #expect(WorkLogCopy.label(entry("grep", .search, path: "TODO")) == "検索 TODO")
        #expect(WorkLogCopy.label(entry("linear_create", .other)) == "linear_create")
    }

    @Test func statusSaysHowTheCallEnded() {
        #expect(WorkLogCopy.status(entry("exec", .command, state: .failed, exitCode: 2), live: false) == "終了コード 2")
        #expect(WorkLogCopy.status(entry("read", .read, state: .failed), live: false) == "失敗")
        #expect(WorkLogCopy.status(entry("exec", .command, durationMs: 4210), live: false) == "4.2秒")
        #expect(WorkLogCopy.status(entry("read", .read, durationMs: 300), live: false) == nil)
        #expect(WorkLogCopy.status(entry("exec", .command, state: .blocked), live: true) == "承認待ち")
        #expect(WorkLogCopy.status(entry("exec", .command, state: .blocked), live: false) == "承認が必要でした")
        #expect(WorkLogCopy.status(entry("exec", .command, state: .unknown), live: false) == "結果不明")
    }
}
