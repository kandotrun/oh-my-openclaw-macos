import Testing
@testable import OhMyOpenClawCore

@Suite("Tool activity classifier")
struct ToolActivityClassifierTests {
    @Test func namesAreCanonicalized() {
        #expect(ToolActivityClassifier.canonicalCall(name: "Bash", args: .object([:])).name == "bash")
        #expect(ToolActivityClassifier.canonicalCall(name: "mcp__openclaw__read", args: .object(["path": .string("a")])).name == "read")
        #expect(ToolActivityClassifier.canonicalCall(name: "mcp_openclaw_exec", args: .object([:])).name == "exec")
    }

    @Test func dispatchWrappersUnwrapToTheInnerTool() {
        let fetch = ToolActivityClassifier.canonicalCall(name: "dispatch_action", args: .object([
            "id": .string("openclaw:core:web_fetch"), "args": .object(["url": .string("https://example.com")]),
        ]))
        #expect(fetch.name == "web_fetch")
        #expect(fetch.args["url"].stringValue == "https://example.com")
        #expect(ToolActivityClassifier.canonicalCall(name: "tool_call", args: .object(["id": .string("grep"), "args": .object(["pattern": .string("x")])])).name == "grep")
        #expect(ToolActivityClassifier.canonicalCall(name: "dispatch_action", args: .object([:])).name == "dispatch_action")
    }

    @Test func kindsFollowTheToolNames() {
        let kind = { (name: String) in ToolActivityClassifier.kind(name: name, args: .object([:])) }
        #expect(kind("bash") == .command)
        #expect(kind("exec") == .command)
        #expect(kind("read_file") == .read)
        #expect(kind("apply_patch") == .edit)
        #expect(kind("write") == .write)
        #expect(kind("web_search") == .search)
        #expect(kind("grep") == .search)
        #expect(kind("web_fetch") == .fetch)
        #expect(kind("sessions_spawn") == .subagent)
        #expect(kind("dispatch_action") == .other)
        #expect(ToolActivityClassifier.kind(name: "sessions_spawn", args: .object([:]), failed: true) == .other)
    }

    @Test func aCommandArgumentMakesAnyToolACommand() {
        #expect(ToolActivityClassifier.kind(name: "linear.create_issue", args: .object(["command": .string("ls")])) == .command)
    }

    @Test func summariesComeFromTheArgumentThatMatters() {
        #expect(ToolActivityClassifier.summary(kind: .command, args: .object(["command": .string("swift   test\n --filter A")])) == "swift test --filter A")
        #expect(ToolActivityClassifier.summary(kind: .read, args: .object(["file_path": .string("a.swift")])) == "a.swift")
        #expect(ToolActivityClassifier.summary(kind: .search, args: .object(["query": .string("flaky test")])) == "flaky test")
        #expect(ToolActivityClassifier.summary(kind: .fetch, args: .object(["url": .string("https://example.com")])) == "https://example.com")
        #expect(ToolActivityClassifier.summary(kind: .subagent, args: .object(["task": .string("Fix the build\nthen test")])) == "Fix the build")
        #expect(ToolActivityClassifier.summary(kind: .other, args: .object([:]), meta: "q") == "q")
        #expect(ToolActivityClassifier.summary(kind: .other, args: .object([:])) == "")
    }

    @Test func longCommandsAreShortenedForTheSummary() {
        let command = String(repeating: "a", count: 300)
        let summary = ToolActivityClassifier.summary(kind: .command, args: .object(["command": .string(command)]))
        #expect(summary.utf16.count <= 200)
    }

    @Test func searchingToolsDriveTheSearchingIndicator() {
        #expect(ToolActivityClassifier.indicatesSearching("web_search"))
        #expect(ToolActivityClassifier.indicatesSearching("browser"))
        #expect(!ToolActivityClassifier.indicatesSearching("exec"))
    }
}
