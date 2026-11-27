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
    /// Units keep their row position, so a call whose result lands late is placed by that result.
    /// A gap stands where a unit went to the other list, at that unit's position.
    private enum Unit { case message(ChatMessage, order: Int), entry(WorkLogEntry, order: Int), gap(order: Int) }
    private struct Turn { var prompt: ChatMessage?; var units: [Unit] = [] }

    static func build(_ input: TimelineInput) -> [TimelineItem] {
        turns(input).flatMap { items(for: $0, input: input) }
    }

    private static func turns(_ input: TimelineInput) -> [Turn] {
        var turns: [Turn] = []
        let rows = input.rows
        var lastRow: [String: Int] = [:]
        for (index, row) in rows.enumerated() { if let source = row.sourceID { lastRow[source] = index } }
        for (index, row) in rows.enumerated() {
            let firstOfRecord = row.sourceID == nil || index == 0 || rows[index - 1].sourceID != row.sourceID
            // A hidden wake or a forwarded post starts a turn even without a visible prompt.
            let boundary = firstOfRecord && row.sourceID.map { input.page?.turnStarts.contains($0) == true } == true
            if row.isConversationMessage && startsTurn(row, page: input.page) {
                turns.append(Turn(prompt: row))
            } else {
                if boundary || (turns.isEmpty && row.isConversationMessage) { turns.append(Turn()) }
                if row.isConversationMessage { turns[turns.count - 1].units.append(.message(row, order: index)) }
            }
            // A record's work follows its last row.
            guard let source = row.sourceID, lastRow[source] == index,
                  let entries = input.page?.entries[source]?.filter({ !$0.isRoutine }), !entries.isEmpty else { continue }
            if turns.isEmpty { turns.append(Turn()) }
            turns[turns.count - 1].units += entries.map { entry in
                .entry(entry, order: max(index, entry.resultRecordID.flatMap { lastRow[$0] } ?? index))
            }
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
        let entries = turn.units.compactMap { unit -> WorkLogEntry? in if case .entry(let entry, _) = unit { entry } else { nil } }
        guard !entries.isEmpty else { return head + grouped(turn.units, input: input, live: false) }
        let runs = runIDs(turn, entries: entries)
        if !runs.isDisjoint(with: input.page?.failedRuns ?? []) || turn.units.contains(where: isFailedReply) {
            // A failed run lists every call, so nothing that went wrong hides in a group.
            return head + turn.units.compactMap { unit in
                switch unit {
                case .message(let row, _): message(row, input)
                case .entry(let entry, _): .entry(entry, live: false)
                case .gap: nil
                }
            }
        }
        if let active = input.activeRunID, runs.contains(active) { return head + grouped(turn.units, input: input, live: true) }
        // Settled: fold the work, and keep the answer, people, images, and late problems in view.
        let terminal = turn.units.last { unit in
            guard case .message(let row, _) = unit, row.role == .assistant, !row.text.isEmpty || !row.attachments.isEmpty else { return false }
            guard let page = input.page, let source = row.sourceID, page.records.contains(source) else { return true }
            return page.finalReplies.contains(source)
        }.map(order)
        var folded: [Unit] = [], shown: [Unit] = []
        for unit in turn.units {
            let keep: Bool = switch unit {
            case .message(let row, let position):
                position == terminal || row.role == .user || !row.attachments.isEmpty || terminal.map { position > $0 } == true
            case .entry(let entry, let position):
                terminal.map { position > $0 } == true && [.failed, .blocked].contains(entry.state)
            case .gap: false
            }
            // A row that leaves one list breaks the groups in the other.
            if keep { shown.append(unit); folded.append(.gap(order: order(unit))) } else { folded.append(unit); shown.append(.gap(order: order(unit))) }
        }
        guard folded.contains(where: { if case .entry = $0 { true } else { false } }) else {
            return head + grouped(chronological(turn.units), input: input, live: false)
        }
        let fold = TurnFold(id: "fold|" + (turn.prompt?.id ?? entries[0].id), label: label(turn, entries: entries, input: input),
                            items: grouped(folded, input: input, live: false))
        return head + [.fold(fold)] + grouped(chronological(shown), input: input, live: false)
    }

    private static func order(_ unit: Unit) -> Int {
        switch unit {
        case .message(_, let position), .entry(_, let position), .gap(let position): position
        }
    }

    /// Late results move after the rows they followed; ties keep their turn order.
    private static func chronological(_ units: [Unit]) -> [Unit] {
        units.enumerated().sorted { (order($0.element), $0.offset) < (order($1.element), $1.offset) }.map(\.element)
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
            case .message(let row, _):
                flush(trailing: false)
                items.append(message(row, input))
            case .entry(let entry, _):
                if let last = pending.last, last.runID != entry.runID { flush(trailing: false) }
                pending.append(entry)
            case .gap:
                flush(trailing: false)
            }
        }
        flush(trailing: true)
        return items
    }

    private static func message(_ row: ChatMessage, _ input: TimelineInput) -> TimelineItem {
        .message(row, SenderStyle.attribution(of: row, viewer: input.viewer))
    }

    private static func isFailedReply(_ unit: Unit) -> Bool {
        if case .message(let row, _) = unit { row.role == .assistant && row.delivery == .failed } else { false }
    }

    private static func runIDs(_ turn: Turn, entries: [WorkLogEntry]) -> Set<String> {
        var runs = Set(entries.compactMap(\.runID))
        let rows = (turn.prompt.map { [$0] } ?? []) + turn.units.compactMap { unit in if case .message(let row, _) = unit { row } else { nil } }
        for row in rows {
            if let run = row.runID { runs.insert(run) }
            if let key = row.idempotencyKey { runs.insert(key.hasSuffix(":user") ? String(key.dropLast(5)) : key) }
        }
        return runs
    }

    /// "27秒作業しました": from the prompt to the last recorded row of the turn.
    private static func label(_ turn: Turn, entries: [WorkLogEntry], input: TimelineInput) -> String {
        guard let page = input.page, let start = turn.prompt?.sourceID.flatMap({ page.recordTimes[$0] }) else { return "作業しました" }
        let sources = turn.units.compactMap { unit -> String? in if case .message(let row, _) = unit { row.sourceID } else { nil } }
            + entries.flatMap { [$0.anchorRecordID, $0.resultRecordID].compactMap { $0 } }
        guard let end = sources.compactMap({ page.recordTimes[$0] }).max(), end > start else { return "作業しました" }
        return WorkDuration.format(milliseconds: Int((end.timeIntervalSince(start) * 1000).rounded())) + "作業しました"
    }
}
