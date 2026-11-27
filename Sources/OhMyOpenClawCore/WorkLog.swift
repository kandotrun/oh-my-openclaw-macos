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
    /// The record that holds the call, or the result record when the call is not on this page.
    public var anchorRecordID: String
    public var resultRecordID: String?
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
    public init() {}
}
