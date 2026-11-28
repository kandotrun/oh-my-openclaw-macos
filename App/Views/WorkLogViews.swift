import SwiftUI
import OhMyOpenClawCore

/// One timeline item: a message, a tool call, a group of calls, or a settled turn's fold.
struct TimelineItemView: View {
    let item: TimelineItem
    @Binding var expanded: Set<String>
    let agentName: (String) -> String
    let retry: (String) -> Void

    var body: some View {
        switch item {
        case .message(let message, let attribution):
            MessageRow(message: message, attribution: attribution, agentName: agentName, retry: { retry(message.id) })
        case .entry(let entry, let live):
            WorkEntryRow(entry: entry, live: live, expanded: $expanded)
        case .group(let group):
            WorkGroupRow(group: group, expanded: $expanded)
        case .fold(let fold):
            WorkFoldRow(fold: fold, expanded: $expanded) { child in
                AnyView(TimelineItemView(item: child, expanded: $expanded, agentName: agentName, retry: retry))
            }
        }
    }
}

private func toggle(_ id: String, in expanded: Binding<Set<String>>) {
    if expanded.wrappedValue.contains(id) { expanded.wrappedValue.remove(id) } else { expanded.wrappedValue.insert(id) }
}

private struct Chevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(open ? .degrees(90) : .zero)
    }
}

/// "27秒作業しました": a settled turn's work, collapsed until opened.
struct WorkFoldRow: View {
    let fold: TurnFold
    @Binding var expanded: Set<String>
    let content: (TimelineItem) -> AnyView

    private var open: Bool { expanded.contains(fold.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { toggle(fold.id, in: $expanded) } } label: {
                HStack(spacing: 6) {
                    Text(fold.label).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Chevron(open: open)
                    VStack { Divider().opacity(0.6) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workFold")
            if open {
                ForEach(fold.items) { content($0) }
            }
        }
    }
}

/// Consecutive calls of one run in one line, opening into the calls.
struct WorkGroupRow: View {
    let group: WorkGroup
    @Binding var expanded: Set<String>

    private var open: Bool { expanded.contains(group.id) }
    private var failed: Bool { group.entries.contains { $0.state == .failed } }
    private var symbol: String {
        let kinds = Set(group.entries.map(\.kind))
        return kinds.count == 1 ? WorkLogSymbol.name(kinds.first!) : "hammer"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.snappy) { toggle(group.id, in: $expanded) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                    Text(group.sentence).font(.callout).lineLimit(1).truncationMode(.tail)
                    if group.live { ProgressView().controlSize(.mini) }
                    Chevron(open: open)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.sentence + (failed ? "、失敗した操作があります" : ""))
            .accessibilityIdentifier("workGroup")
            if open {
                ForEach(group.entries) { entry in
                    WorkEntryRow(entry: entry, live: group.live, expanded: $expanded).padding(.leading, 24)
                }
            }
        }
    }
}

/// One tool call: what it touched, how it ended, and its output or diff when opened.
struct WorkEntryRow: View {
    let entry: WorkLogEntry
    let live: Bool
    @Binding var expanded: Set<String>

    private var open: Bool { expanded.contains(entry.id) }
    private var running: Bool { entry.state == .running || (live && entry.state == .unknown) }
    private var hasDetail: Bool { entry.command != nil || entry.output != nil || entry.diff != nil || (entry.exitCode ?? 0) != 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { toggle(entry.id, in: $expanded) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: WorkLogSymbol.name(entry.kind)).frame(width: 16)
                        .foregroundStyle(entry.state == .failed ? Color.red : Color.secondary)
                    Text(WorkLogCopy.label(entry))
                        .font(entry.kind == .command ? .callout.monospaced() : .callout)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if running { ProgressView().controlSize(.mini) }
                    else if let status = WorkLogCopy.status(entry, live: live) {
                        Text(status).font(.caption).monospacedDigit().foregroundStyle(entry.state == .failed ? Color.red : Color.secondary)
                    }
                    if hasDetail { Chevron(open: open) }
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            .accessibilityIdentifier("workEntry")
            if open && hasDetail { WorkEntryDetail(entry: entry).padding(.leading, 22) }
        }
    }
}

private struct WorkEntryDetail: View {
    let entry: WorkLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = entry.command {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let diff = entry.diff { DiffLinesView(diff: diff) }
            if let output = entry.output {
                ScrollView {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .accessibilityIdentifier("workEntryOutput")
            } else if entry.diff == nil && entry.command != nil {
                Text("出力はありません。").font(.caption).foregroundStyle(.secondary)
            }
            if entry.outputTruncated { Text("出力の一部のみ表示しています。").font(.caption).foregroundStyle(.secondary) }
            if let code = entry.exitCode, code != 0 { Text("終了コード \(code)").font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DiffLinesView: View {
    let diff: ToolDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let stat = diff.stat { Text("+\(stat.added) -\(stat.removed)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 8) {
                            Text(line.number.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
                            Text(text(line)).fontWeight(line.kind == .file ? .semibold : .regular)
                        }
                        .font(.caption.monospaced())
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                        .accessibilityLabel(accessible(line))
                    }
                }
            }
            .frame(maxHeight: 320)
            if diff.isClipped { Text("差分の一部のみ表示しています。").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func text(_ line: ToolDiff.Line) -> String {
        switch line.kind {
        case .added: "+ " + line.text
        case .removed: "- " + line.text
        case .skip: "⋯"
        case .context, .file: line.text
        }
    }

    private func background(_ line: ToolDiff.Line) -> Color {
        switch line.kind {
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.12)
        default: .clear
        }
    }

    private func accessible(_ line: ToolDiff.Line) -> String {
        switch line.kind {
        case .added: "追加 " + line.text
        case .removed: "削除 " + line.text
        case .skip: "省略"
        case .context, .file: line.text
        }
    }
}

enum WorkLogSymbol {
    static func name(_ kind: WorkLogKind) -> String {
        switch kind {
        case .command: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .write: "square.and.pencil"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        case .subagent: "person.2"
        case .other: "wrench.and.screwdriver"
        }
    }
}
