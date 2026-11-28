import Foundation
import OhMyOpenClawCore

/// T3 Code's duration copy, in Japanese.
enum WorkDuration {
    static func format(milliseconds: Int) -> String {
        guard milliseconds >= 0 else { return "0ミリ秒" }
        if milliseconds < 1000 { return "\(max(1, milliseconds))ミリ秒" }
        if milliseconds < 10_000 {
            let tenths = Int((Double(milliseconds) / 100).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)秒" : "\(tenths / 10).\(tenths % 10)秒"
        }
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        if seconds < 60 { return "\(seconds)秒" }
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        if hours == 0 { return "\(minutes)分\(rest)秒" }
        if minutes == 0 { return rest == 0 ? "\(hours)時間" : "\(hours)時間\(rest)秒" }
        return "\(hours)時間\(minutes)分\(rest)秒"
    }
}

/// Labels and sentences for the work log, after T3 Code's work log presentation.
enum WorkLogCopy {
    private enum Bucket: Equatable { case command, edit, read, search, fetch, subagent, other, remainder }

    /// "コマンドを3回実行し、4件のファイルを読み込みました": the two most telling kinds, then the rest.
    static func sentence(_ entries: [WorkLogEntry]) -> String {
        struct Tally { var bucket: Bucket; var first: Int; var entries = 0; var paths = Set<String>(); var pathless = 0 }
        var tallies: [Tally] = []
        for (index, entry) in entries.enumerated() {
            let bucket = bucket(entry.kind)
            let position = tallies.firstIndex { $0.bucket == bucket } ?? { tallies.append(Tally(bucket: bucket, first: index)); return tallies.count - 1 }()
            tallies[position].entries += 1
            // A patch can change several files; its diff lists them all.
            let paths = entry.diff.map(\.files).flatMap { $0.isEmpty ? nil : $0 } ?? (entry.summary.isEmpty ? [] : [entry.summary])
            if paths.isEmpty { tallies[position].pathless += 1 } else { tallies[position].paths.formUnion(paths) }
        }
        let kept = tallies.sorted { (priority($0.bucket), $0.first) < (priority($1.bucket), $1.first) }.prefix(2).sorted { $0.first < $1.first }
        var clauses = kept.map { ($0.bucket, $0.bucket == .edit ? $0.paths.count + $0.pathless : $0.entries) }
        let remainder = entries.count - kept.reduce(0) { $0 + $1.entries }
        if remainder > 0 { clauses.append((.remainder, remainder)) }
        return clauses.enumerated().map { index, clause in phrase(clause.0, clause.1, final: index == clauses.count - 1) }.joined(separator: "、")
    }

    static func label(_ entry: WorkLogEntry) -> String {
        let target = entry.summary
        switch entry.kind {
        case .command: return target.isEmpty ? entry.name : target
        case .read: return joined("読み込み", target)
        case .edit:
            let files = entry.diff?.files ?? []
            return files.count > 1 ? "編集 \(files[0]) ほか\(files.count - 1)件" : joined("編集", target)
        case .write: return joined("書き込み", target)
        case .search: return joined("検索", target)
        case .fetch: return joined("取得", target)
        case .subagent: return joined("サブエージェント", target)
        case .other: return joined(entry.title ?? entry.name, target)
        }
    }

    /// Nil while running, and for quick successes that need no number.
    static func status(_ entry: WorkLogEntry, live: Bool) -> String? {
        switch entry.state {
        case .running: nil
        case .completed: entry.durationMs.flatMap { $0 >= 1000 ? WorkDuration.format(milliseconds: $0) : nil }
        case .failed: entry.exitCode.flatMap { $0 != 0 ? "終了コード \($0)" : nil } ?? "失敗"
        case .blocked: live ? "承認待ち" : "承認が必要でした"
        case .skipped: "スキップ"
        case .unknown: live ? nil : "結果不明"
        }
    }

    private static func bucket(_ kind: WorkLogKind) -> Bucket {
        switch kind {
        case .command: .command
        case .edit, .write: .edit
        case .read: .read
        case .search: .search
        case .fetch: .fetch
        case .subagent: .subagent
        case .other: .other
        }
    }

    private static func priority(_ bucket: Bucket) -> Int {
        switch bucket {
        case .command, .edit: 0
        case .read, .search, .fetch, .subagent: 1
        case .other, .remainder: 2
        }
    }

    private static func phrase(_ bucket: Bucket, _ count: Int, final: Bool) -> String {
        let (stem, continuative, finished): (String, String, String) = switch bucket {
        case .command: ("コマンドを\(count)回実行", "し", "しました")
        case .edit: ("\(count)件のファイルを変更", "し", "しました")
        case .read: ("\(count)件のファイルを読み込", "み", "みました")
        case .search: ("\(count)回検索", "し", "しました")
        case .fetch: ("\(count)件のページを取得", "し", "しました")
        case .subagent: ("\(count)件のサブエージェントを起動", "し", "しました")
        case .other: ("ツールを\(count)回使用", "し", "しました")
        case .remainder: ("ほかに\(count)件の操作を行", "い", "いました")
        }
        return stem + (final ? finished : continuative)
    }

    private static func joined(_ prefix: String, _ target: String) -> String { target.isEmpty ? prefix : prefix + " " + target }
}
