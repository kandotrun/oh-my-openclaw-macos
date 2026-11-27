import Foundation

/// Builds the work log from `chat.history` records and their `activity` items.
/// Record ids match `ConversationStore.parseMessages`, so entries anchor to transcript rows.
public enum WorkLogProjection {
    private static let callTypes: Set<String> = ["toolcall", "tool_call", "tooluse", "tool_use", "function_call"]
    private static let resultTypes: Set<String> = ["toolresult", "tool_result", "function_call_output"]
    private static let resultRoles: Set<String> = ["toolresult", "tool_result", "tool", "function"]
    private static let idFields = ["id", "tool_call_id", "toolCallId", "tool_use_id", "toolUseId"]

    private struct Position { var anchor: String; var index: Int; var turn: Int; var run: String?; var callID: String }

    public static func project(messages: [JSONValue], activity: JSONValue, fallbackPrefix: String) -> WorkLogPage {
        var page = WorkLogPage()
        let records = messages.enumerated().map { index, value in
            (id: value["__openclaw"]["id"].stringValue ?? value["id"].stringValue ?? "\(fallbackPrefix):\(index)", value: value)
        }
        // Outcomes and times come from every record, including rows the transcript hides.
        for record in records {
            page.records.insert(record.id)
            if let ms = record.value["__openclaw"]["recordTimestampMs"].numberValue ?? record.value["timestamp"].numberValue {
                page.recordTimes[record.id] = Date(timeIntervalSince1970: ms / 1000)
            }
            if record.value["customType"].stringValue == "run-failed-before-reply",
               let run = record.value["openclawRunError"]["runId"].stringValue ?? record.value["details"]["runId"].stringValue {
                page.failedRuns.insert(run)
            }
        }
        var calls: [Position] = []
        var turn = 0
        for record in records where isVisible(record.value) {
            let value = record.value
            let role = value["role"].stringValue?.lowercased() ?? ""
            let run = value["__openclaw"]["runId"].stringValue ?? value["runId"].stringValue
            let blocks = value["content"].arrayValue ?? []
            if startsTurn(value, role: role, blocks: blocks) { turn += 1; page.turnStarts.insert(record.id) }
            // Commentary rows narrate the work, so they never answer the turn.
            if role == "assistant", value["openclawStreamFallback"] == .null, !blocks.contains(where: { callTypes.contains(type($0)) }),
               !(value["stopReason"].stringValue ?? "").lowercased().hasPrefix("tool") {
                page.finalReplies.insert(record.id)
            }
            if resultRoles.contains(role) || (role != "user" && firstID(value) != nil && !blocks.contains { callTypes.contains(type($0)) }) {
                attach(result: value, block: nil, record: record.id, run: run, turn: turn, calls: calls, page: &page)
                continue
            }
            for (index, block) in blocks.enumerated() {
                let kind = type(block)
                if callTypes.contains(kind) {
                    let callID = firstID(block) ?? "history:\(record.id):\(index)"
                    let entry = makeCall(block, callID: callID, anchor: record.id, run: block["runId"].stringValue ?? run)
                    page.entries[record.id, default: []].append(entry)
                    calls.append(Position(anchor: record.id, index: page.entries[record.id]!.count - 1, turn: turn, run: entry.runID, callID: callID))
                } else if resultTypes.contains(kind) {
                    attach(result: value, block: block, record: record.id, run: block["runId"].stringValue ?? run, turn: turn, calls: calls, page: &page)
                }
            }
        }
        overlay(activity, on: &page)
        for (anchor, entries) in page.entries {
            for index in entries.indices { page.entries[anchor]![index].settleKind() }
        }
        return page
    }

    private static func isVisible(_ value: JSONValue) -> Bool {
        let role = value["role"].stringValue?.lowercased() ?? ""
        // Nested tool records are custom rows that carry an inner call and its result.
        if value["customType"].stringValue == "openclaw.nested-tool.v1" { return value["display"].boolValue != false }
        return value["display"].boolValue != false && value["customType"].stringValue != "openclaw.runtime-context"
            && !["system", "developer", "custom"].contains(role)
    }

    /// The server's turn counter: prompts and hidden wakes start turns; steers, human-addressed
    /// notes, tool-result carriers, and continuations of an earlier turn do not.
    private static func startsTurn(_ value: JSONValue, role: String, blocks: [JSONValue]) -> Bool {
        let meta = value["__openclaw"]
        if meta["turnBoundary"].boolValue == true { return meta["continuation"] == .null }
        if value["senderSession"] != .null { return true }
        guard role == "user", !blocks.contains(where: { resultTypes.contains(type($0)) }) else { return false }
        return meta["steerTargetRunId"].stringValue == nil && meta["humanAddressed"].boolValue != true
    }

    private static func makeCall(_ block: JSONValue, callID: String, anchor: String, run: String?) -> WorkLogEntry {
        var arguments = block["arguments"] != .null ? block["arguments"] : (block["args"] != .null ? block["args"] : block["input"])
        if let encoded = arguments.stringValue, let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)) {
            arguments = decoded
        }
        let call = ToolActivityClassifier.canonicalCall(name: block["name"].stringValue ?? block["toolName"].stringValue ?? "tool", args: arguments)
        let kind = ToolActivityClassifier.kind(name: call.name, args: call.args)
        var entry = WorkLogEntry(id: anchor + "|" + callID, toolCallID: callID, runID: run, name: call.name, kind: kind, state: .unknown,
                                 summary: ToolActivityClassifier.summary(kind: kind, args: call.args), anchorRecordID: anchor)
        entry.command = kind == .command ? call.args["command"].stringValue : nil
        if let envelope = call.args["input"].stringValue { entry.diff = ToolDiff.patchEnvelope(envelope) }
        if entry.diff == nil, let changes = call.args["changes"].arrayValue {
            entry.diff = ToolDiff.joined(changes.compactMap { change in
                change["diff"].stringValue.flatMap { text in
                    let stat = change["stat"]["added"].intValue.flatMap { added in change["stat"]["removed"].intValue.map { ToolDiff.Stat(added: added, removed: $0) } }
                    return ToolDiff.unified(text, path: change["path"].stringValue ?? "", stat: stat, truncated: change["diffTruncated"].boolValue == true)
                }
            })
        }
        return entry
    }

    private static func attach(result value: JSONValue, block: JSONValue?, record: String, run: String?, turn: Int,
                               calls: [Position], page: inout WorkLogPage) {
        let source = block ?? value
        guard let callID = block.flatMap({ firstID($0, skippingID: true) ?? firstID($0) }) ?? firstID(value, skippingID: true) else { return }
        let meta = value["__openclaw"]
        let content = source["content"]
        let output = content.stringValue ?? content.arrayValue?.compactMap { $0["text"].stringValue }.joined(separator: "\n")
        let details = source["details"] != .null ? source["details"] : value["details"]
        let truncated = meta["truncated"].boolValue == true || meta["reason"].stringValue == "oversized"
        let position = calls.last { $0.callID == callID && $0.turn == turn && $0.run == run }
            ?? calls.last { $0.callID == callID && $0.turn == turn } ?? calls.last { $0.callID == callID }
        var entry: WorkLogEntry
        if let position { entry = page.entries[position.anchor]![position.index] }
        else {
            let name = ToolActivityClassifier.canonicalCall(name: value["toolName"].stringValue ?? value["tool_name"].stringValue ?? "tool", args: .null).name
            entry = WorkLogEntry(id: record + "|" + callID, toolCallID: callID, runID: run, name: name,
                                 kind: ToolActivityClassifier.kind(name: name, args: .null), state: .unknown, summary: "", anchorRecordID: record)
            entry.hasCall = false
        }
        entry.resultRecordID = record
        entry.output = truncated && meta["reason"].stringValue == "oversized" ? nil : output.flatMap { $0.isEmpty ? nil : $0 }
        entry.outputTruncated = truncated
        entry.exitCode = details["exitCode"].intValue ?? source["exitCode"].intValue ?? source["exit_code"].intValue
        if let duration = details["durationMs"].intValue { entry.durationMs = duration }
        else if let start = page.recordTimes[entry.anchorRecordID], let end = page.recordTimes[record], position != nil {
            entry.durationMs = Int((end.timeIntervalSince(start) * 1000).rounded())
        }
        if let numbered = details["diff"].stringValue.flatMap({ ToolDiff.numbered($0, truncated: truncated) }) { entry.diff = numbered }
        let failed = (source["isError"].boolValue ?? source["is_error"].boolValue) == true
            || (ToolActivityClassifier.isShell(entry.name) && (entry.exitCode ?? 0) != 0)
        entry.state = failed ? .failed : .completed
        if let position { page.entries[position.anchor]![position.index] = entry } else { page.entries[record, default: []].append(entry) }
    }

    /// Activity items carry the authoritative status; a record whose list omits a tool hides it as routine.
    private static func overlay(_ activity: JSONValue, on page: inout WorkLogPage) {
        var lists: [String: [JSONValue]] = [:]
        for group in activity.arrayValue ?? [] {
            if let id = group["messageId"].stringValue { lists[id] = group["items"].arrayValue ?? [] }
        }
        guard !lists.isEmpty else { return }
        for (anchor, entries) in page.entries {
            for index in entries.indices {
                var entry = entries[index]
                let records = [entry.resultRecordID, entry.anchorRecordID].compactMap { $0 }
                let item = records.lazy.compactMap { lists[$0] }.flatMap { $0 }
                    .first { $0["toolCallId"].stringValue == entry.toolCallID && ($0["kind"].stringValue ?? "tool") == "tool" }
                if let item {
                    entry.title = item["title"].stringValue ?? entry.title
                    if entry.summary.isEmpty { entry.summary = item["summary"].stringValue ?? item["meta"].stringValue ?? "" }
                    if item["unpairedCall"].boolValue == true { entry.state = .unknown }
                    else if let status = item["status"].stringValue.flatMap(WorkLogState.init(rawValue:)) { entry.state = status }
                    else if entry.resultRecordID != nil { entry.state = .unknown }
                } else if records.contains(where: { lists[$0] != nil }) {
                    entry.isRoutine = true
                }
                page.entries[anchor]![index] = entry
            }
        }
    }

    private static func type(_ block: JSONValue) -> String { block["type"].stringValue?.lowercased() ?? "" }

    private static func firstID(_ value: JSONValue, skippingID: Bool = false) -> String? {
        for field in idFields where !(skippingID && field == "id") {
            if let id = value[field].stringValue, !id.isEmpty { return id }
        }
        return nil
    }
}
