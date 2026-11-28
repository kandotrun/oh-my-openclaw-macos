import Foundation

public enum WorkLogState: String, Sendable, Equatable {
    case running, completed, failed, blocked, skipped
    /// No recorded outcome: the call has no result yet, or OpenClaw repaired a missing one.
    case unknown
}

/// One tool call in a turn's work log. It lives only in memory: tool output never reaches disk.
public struct WorkLogEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var toolCallID: String
    public var runID: String?
    public var name: String
    public var kind: WorkLogKind
    public var state: WorkLogState
    public var title: String?
    public var summary: String
    /// The full shell command, for the detail panel.
    public var command: String?
    public var output: String?
    public var outputTruncated = false
    public var exitCode: Int?
    public var durationMs: Int?
    public var diff: ToolDiff?
    /// OpenClaw hides routine calls such as polling from progress lists.
    public var isRoutine = false
    /// The page's activity list for this call's records described it.
    public var hasActivityItem = false
    /// The record that holds the call, or the result record when the call is not on this page.
    public var anchorRecordID: String
    /// False for a result whose call is on another page.
    public var hasCall = true
    public var resultRecordID: String?

    public init(id: String, toolCallID: String, runID: String?, name: String, kind: WorkLogKind, state: WorkLogState,
                title: String? = nil, summary: String, anchorRecordID: String) {
        self.id = id; self.toolCallID = toolCallID; self.runID = runID; self.name = name; self.kind = kind
        self.state = state; self.title = title; self.summary = summary; self.anchorRecordID = anchorRecordID
    }
}

extension WorkLogEntry {
    /// A sub-agent that failed, was blocked, or was skipped did no work of its own.
    mutating func settleKind() {
        if kind == .subagent && [.failed, .blocked, .skipped].contains(state) { kind = .other }
    }
}

/// The work log projected from one `chat.history` page, keyed by transcript record id.
public struct WorkLogPage: Sendable, Equatable {
    /// Entries in block order under the record that anchors them.
    public var entries: [String: [WorkLogEntry]] = [:]
    /// Records that start a turn: prompts and hidden wakes, not steers, tool results, or continuations.
    public var turnStarts: Set<String> = []
    public var recordTimes: [String: Date] = [:]
    /// Runs that ended in a failure before replying.
    public var failedRuns: Set<String> = []
    /// Every record id on the page, so rows from elsewhere (queued inputs, local sends) can be told apart.
    public var records: Set<String> = []
    /// Assistant records that answer rather than call tools: the candidates for a turn's final reply.
    public var finalReplies: Set<String> = []
    public init() {}

    /// This page with an older page's records added; this page wins where both hold a record.
    public func adding(older: WorkLogPage) -> WorkLogPage {
        var merged = self
        merged.entries = older.entries.merging(entries) { _, newer in newer }
        merged.turnStarts.formUnion(older.turnStarts)
        merged.recordTimes = older.recordTimes.merging(recordTimes) { _, newer in newer }
        merged.failedRuns.formUnion(older.failedRuns)
        merged.records.formUnion(older.records)
        merged.finalReplies.formUnion(older.finalReplies)
        // A result whose call sits on the older page joins that call's entry.
        for (anchor, list) in merged.entries {
            for orphan in list where !orphan.hasCall {
                guard let (callAnchor, index) = merged.entries.lazy.compactMap({ key, entries in
                    // A refresh brings the orphan back after an earlier join, so the joined call matches again.
                    entries.firstIndex { $0.hasCall && ($0.resultRecordID == nil || $0.resultRecordID == orphan.resultRecordID)
                        && $0.toolCallID == orphan.toolCallID && ($0.runID == nil || orphan.runID == nil || $0.runID == orphan.runID) }.map { (key, $0) }
                }).first else { continue }
                var call = merged.entries[callAnchor]![index]
                // The result record names its tool, so the orphan's state already counts a shell's exit code.
                call.state = orphan.state
                call.output = orphan.output; call.outputTruncated = orphan.outputTruncated
                call.exitCode = orphan.exitCode; call.durationMs = orphan.durationMs ?? call.durationMs
                call.diff = orphan.diff ?? call.diff; call.resultRecordID = orphan.resultRecordID
                if call.title == nil { call.title = orphan.title }
                // Each page's activity is computed alone. Where the result's record has a list, it knew the
                // outcome, which can make a call routine, so it decides.
                if orphan.hasActivityItem || orphan.isRoutine { call.isRoutine = orphan.isRoutine }
                call.settleKind()
                merged.entries[callAnchor]![index] = call
                merged.entries[anchor]?.removeAll { $0.id == orphan.id }
            }
        }
        return merged
    }
}
