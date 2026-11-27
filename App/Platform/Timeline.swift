import Foundation
import OhMyOpenClawCore

/// Consecutive tool calls of one run, summed up in one sentence.
struct WorkGroup: Equatable, Identifiable {
    var id: String
    var entries: [WorkLogEntry]
    var sentence: String
    /// The run is still adding to this group.
    var live: Bool
}

/// A settled turn's work, collapsed under its prompt as "27秒作業しました".
struct TurnFold: Equatable, Identifiable {
    var id: String
    var label: String
    var items: [TimelineItem]
}

indirect enum TimelineItem: Equatable, Identifiable {
    case message(ChatMessage, Attribution)
    case entry(WorkLogEntry, live: Bool)
    case group(WorkGroup)
    case fold(TurnFold)

    var id: String {
        switch self {
        case .message(let message, _): message.id
        case .entry(let entry, _): "entry|" + entry.id
        case .group(let group): group.id
        case .fold(let fold): fold.id
        }
    }
}

struct TimelineInput {
    /// Every transcript row, hidden ones included: they place each record's work in order.
    var rows: [ChatMessage]
    /// Nil until history has loaded; the transcript then looks as it did before the work log.
    var page: WorkLogPage?
    var activeRunID: String?
    var viewer: ViewerIdentity
}

/// Turns, folds, and groups for the transcript, after T3 Code's timeline.
enum Timeline {
    private enum Unit { case message(ChatMessage), entry(WorkLogEntry) }
    private struct Turn { var prompt: ChatMessage?; var units: [Unit] = [] }

    static func build(_ input: TimelineInput) -> [TimelineItem] {
        turns(input).flatMap { items(for: $0, input: input) }
    }

    private static func turns(_ input: TimelineInput) -> [Turn] {
        var turns: [Turn] = []
        let rows = input.rows
        for (index, row) in rows.enumerated() {
            if row.isConversationMessage {
                if startsTurn(row, page: input.page) { turns.append(Turn(prompt: row)) }
                else {
                    if turns.isEmpty { turns.append(Turn()) }
                    turns[turns.count - 1].units.append(.message(row))
                }
            }
            // A record's work follows its last row.
            guard let source = row.sourceID, index + 1 == rows.count || rows[index + 1].sourceID != source,
                  let entries = input.page?.entries[source]?.filter({ !$0.isRoutine }), !entries.isEmpty else { continue }
            if turns.isEmpty { turns.append(Turn()) }
            turns[turns.count - 1].units += entries.map(Unit.entry)
        }
        return turns
    }

    /// Prompts start turns. Rows from outside the page (local sends, queued inputs) are prompts too.
    private static func startsTurn(_ row: ChatMessage, page: WorkLogPage?) -> Bool {
        guard row.role == .user else { return false }
        guard let page, let source = row.sourceID, page.records.contains(source) else { return true }
        return page.turnStarts.contains(source)
    }

    private static func items(for turn: Turn, input: TimelineInput) -> [TimelineItem] {
        let head: [TimelineItem] = turn.prompt.map { [message($0, input)] } ?? []
        let entries = turn.units.compactMap { unit -> WorkLogEntry? in if case .entry(let entry) = unit { entry } else { nil } }
        guard !entries.isEmpty else { return head + grouped(turn.units, input: input, live: false) }
        let runs = runIDs(turn, entries: entries)
        if !runs.isDisjoint(with: input.page?.failedRuns ?? []) || turn.units.contains(where: isFailedReply) {
            // A failed run lists every call, so nothing that went wrong hides in a group.
            return head + turn.units.map { unit in
                switch unit {
                case .message(let row): message(row, input)
                case .entry(let entry): .entry(entry, live: false)
                }
            }
        }
        if let active = input.activeRunID, runs.contains(active) { return head + grouped(turn.units, input: input, live: true) }
        // Settled: fold the work, and keep the answer, people, images, and late problems in view.
        let terminal = turn.units.lastIndex { unit in if case .message(let row) = unit { row.role == .assistant && !row.text.isEmpty } else { false } }
        var folded: [Unit] = [], shown: [Unit] = []
        for (index, unit) in turn.units.enumerated() {
            switch unit {
            case .message(let row):
                let keep = index == terminal || row.role == .user || !row.attachments.isEmpty || terminal.map { index > $0 } == true
                keep ? shown.append(unit) : folded.append(unit)
            case .entry(let entry):
                let lateProblem = terminal.map { index > $0 } == true && [.failed, .blocked].contains(entry.state)
                lateProblem ? shown.append(unit) : folded.append(unit)
            }
        }
        let fold = TurnFold(id: "fold|" + (turn.prompt?.id ?? entries[0].id), label: label(turn, entries: entries, input: input),
                            items: grouped(folded, input: input, live: false))
        return head + [.fold(fold)] + grouped(shown, input: input, live: false)
    }

    /// Consecutive calls of one run form a group; in a running turn the trailing calls stay a live group.
    private static func grouped(_ units: [Unit], input: TimelineInput, live: Bool) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var pending: [WorkLogEntry] = []
        func flush(trailing: Bool) {
            guard !pending.isEmpty else { return }
            let isLive = live && trailing
            if pending.count == 1 && !isLive { items.append(.entry(pending[0], live: live)) }
            else { items.append(.group(WorkGroup(id: "group|" + pending[0].id, entries: pending, sentence: WorkLogCopy.sentence(pending), live: isLive))) }
            pending = []
        }
        for unit in units {
            switch unit {
            case .message(let row):
                flush(trailing: false)
                items.append(message(row, input))
            case .entry(let entry):
                if let last = pending.last, last.runID != entry.runID { flush(trailing: false) }
                pending.append(entry)
            }
        }
        flush(trailing: true)
        return items
    }

    private static func message(_ row: ChatMessage, _ input: TimelineInput) -> TimelineItem {
        .message(row, SenderStyle.attribution(of: row, viewer: input.viewer))
    }

    private static func isFailedReply(_ unit: Unit) -> Bool {
        if case .message(let row) = unit { row.role == .assistant && row.delivery == .failed } else { false }
    }

    private static func runIDs(_ turn: Turn, entries: [WorkLogEntry]) -> Set<String> {
        var runs = Set(entries.compactMap(\.runID))
        let rows = (turn.prompt.map { [$0] } ?? []) + turn.units.compactMap { unit in if case .message(let row) = unit { row } else { nil } }
        for row in rows {
            if let run = row.runID { runs.insert(run) }
            if let key = row.idempotencyKey { runs.insert(key.hasSuffix(":user") ? String(key.dropLast(5)) : key) }
        }
        return runs
    }

    /// "27秒作業しました": from the prompt to the last recorded row of the turn.
    private static func label(_ turn: Turn, entries: [WorkLogEntry], input: TimelineInput) -> String {
        guard let page = input.page, let start = turn.prompt?.sourceID.flatMap({ page.recordTimes[$0] }) else { return "作業しました" }
        let sources = turn.units.compactMap { unit -> String? in if case .message(let row) = unit { row.sourceID } else { nil } }
            + entries.flatMap { [$0.anchorRecordID, $0.resultRecordID].compactMap { $0 } }
        guard let end = sources.compactMap({ page.recordTimes[$0] }).max(), end > start else { return "作業しました" }
        return WorkDuration.format(milliseconds: Int((end.timeIntervalSince(start) * 1000).rounded())) + "作業しました"
    }
}
