import Foundation

/// What a tool call did, for the work log.
public enum WorkLogKind: String, Sendable, Equatable, CaseIterable {
    case command, read, edit, write, search, fetch, subagent, other
}

/// The only place that knows tool names. It mirrors OpenClaw's activity presentation,
/// and any tool it does not know becomes a generic entry.
public enum ToolActivityClassifier {
    public struct Call: Sendable, Equatable {
        public var name: String
        public var args: JSONValue
    }

    private static let names: [WorkLogKind: Set<String>] = [
        .command: ["exec", "bash", "shell", "run_command", "run_terminal_cmd"],
        .read: ["read", "read_file", "readfile", "notebookread", "notebook_read"],
        .edit: ["edit", "apply_patch", "applypatch", "patch", "edit_file", "multiedit", "multi_edit", "notebookedit", "notebook_edit"],
        .write: ["write", "write_file", "create_file"],
        .search: ["grep", "glob", "find", "ls", "list", "codebase_search", "web_search"],
        .fetch: ["web_fetch", "webfetch", "fetch"],
        .subagent: ["sessions_spawn"],
    ]
    private static let searching: Set<String> = ["web_search", "web_fetch", "browser"]

    /// Strips OpenClaw's MCP prefixes, unwraps `dispatch_action` and `tool_call`, and lowercases.
    public static func canonicalCall(name: String, args: JSONValue) -> Call {
        var name = name
        for prefix in ["mcp__openclaw__", "mcp_openclaw_"] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        var args = args
        if ["dispatch_action", "tool_call"].contains(name.lowercased()), let id = args["id"].stringValue, !id.isEmpty {
            name = id.wholeMatch(of: /(?:openclaw|mcp|client):[^:]+:(.+)/).map { String($0.1) } ?? id
            args = args["args"]
        }
        return Call(name: name.lowercased(), args: args)
    }

    /// A string `command` argument or a command-bearing item makes any tool a command.
    /// A sub-agent that failed, was blocked, or was skipped did no work of its own.
    public static func kind(name: String, args: JSONValue, commandBearing: Bool = false, failed: Bool = false) -> WorkLogKind {
        if commandBearing || isShell(name) || args["command"].stringValue != nil { return .command }
        guard let kind = names.first(where: { $0.value.contains(name) })?.key else { return .other }
        return kind == .subagent && failed ? .other : kind
    }

    public static func isShell(_ name: String) -> Bool { names[.command, default: []].contains(name) }

    /// Tools whose run shows the "searching" activity.
    public static func indicatesSearching(_ name: String) -> Bool { searching.contains(name) }

    /// One line for the entry: the command, path, pattern, URL, or task, else the activity meta.
    public static func summary(kind: WorkLogKind, args: JSONValue, meta: String? = nil) -> String {
        let value: String? = switch kind {
        case .command: args["command"].stringValue.map(collapsed)
        case .read, .write: args["path"].stringValue ?? args["file_path"].stringValue
        case .edit: args["path"].stringValue ?? args["file_path"].stringValue ?? patchPath(args["input"].stringValue)
            ?? args["changes"].arrayValue?.first?["path"].stringValue
        case .search: args["pattern"].stringValue ?? args["query"].stringValue
        case .fetch: args["url"].stringValue
        case .subagent: args["label"].stringValue ?? args["taskName"].stringValue
            ?? args["task"].stringValue?.split(separator: "\n").first.map(String.init)
        case .other: nil
        }
        return truncated(value.flatMap { $0.isEmpty ? nil : $0 } ?? meta ?? "", limit: 200)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func patchPath(_ envelope: String?) -> String? {
        envelope?.firstMatch(of: /\*\*\* (?:Update|Add|Delete) File: (.+)/).map { String($0.1).trimmingCharacters(in: .whitespaces) }
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        for character in text {
            guard result.utf16.count + String(character).utf16.count < limit else { break }
            result.append(character)
        }
        return result + "…"
    }
}
