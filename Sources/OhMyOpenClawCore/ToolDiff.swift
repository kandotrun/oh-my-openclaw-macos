import Foundation

/// A diff to show under an edit in the work log.
public struct ToolDiff: Sendable, Equatable {
    public enum LineKind: Sendable, Equatable { case context, added, removed, skip, file }

    public struct Line: Sendable, Equatable {
        public var kind: LineKind
        public var number: Int?
        public var text: String
        public init(kind: LineKind, number: Int?, text: String) { self.kind = kind; self.number = number; self.text = text }
    }

    public struct Stat: Sendable, Equatable {
        public var added: Int
        public var removed: Int
        public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
    }

    public static let maxLines = 400

    public private(set) var lines: [Line]
    /// Nil when the diff is incomplete, so a count would be wrong.
    public private(set) var stat: Stat?
    public private(set) var files: [String]
    /// More lines exist than `lines` shows.
    public private(set) var isClipped: Bool

    private init(lines: [Line], stat: Stat?, files: [String]) {
        self.lines = Array(lines.prefix(Self.maxLines))
        self.isClipped = lines.count > Self.maxLines
        self.stat = stat
        self.files = files
    }

    /// OpenClaw's numbered history diff: `<sign><padded number> <text>` rows, with elided rows of spaces and `...`.
    public static func numbered(_ text: String, truncated: Bool = false) -> ToolDiff? {
        var lines: [Line] = []
        var incomplete = truncated
        for row in rows(text) where !row.isEmpty {
            if row.wholeMatch(of: /\ +\.\.\./) != nil { lines.append(Line(kind: .skip, number: nil, text: "")); continue }
            if row.wholeMatch(of: /\s*(?:…|\.\.\.)\((?:live output )?truncated\)(?:…|\.\.\.)\s*/) != nil { incomplete = true; continue }
            guard let match = row.wholeMatch(of: /([ +\-]) *(\d+)(?: (.*))?/), let number = Int(match.2) else { return nil }
            lines.append(Line(kind: kind(match.1.first), number: number, text: match.3.map(String.init) ?? ""))
        }
        return make(lines, incomplete: incomplete, files: [], requiresChange: true)
    }

    /// An `apply_patch` envelope: `*** Begin Patch`, file headers, `@@` hunks, and `*** End Patch`.
    public static func patchEnvelope(_ text: String) -> ToolDiff? {
        guard text.contains("*** Begin Patch") else { return nil }
        var lines: [Line] = []
        var files: [String] = []
        var incomplete = false
        for row in rows(text) where !row.isEmpty && !["*** Begin Patch", "*** End Patch", "*** End of File"].contains(row) {
            if let match = row.wholeMatch(of: /\*\*\* (Update|Add|Delete) File: (.+)/) {
                let path = String(match.2).trimmingCharacters(in: .whitespaces)
                files.append(path)
                lines.append(Line(kind: .file, number: nil, text: path))
                // A deleted file's lines are not listed, so its count is unknown.
                if match.1 == "Delete" { incomplete = true }
            } else if let match = row.wholeMatch(of: /\*\*\* Move to: (.+)/), let index = lines.lastIndex(where: { $0.kind == .file }) {
                lines[index].text += " → " + String(match.1).trimmingCharacters(in: .whitespaces)
            } else if row.hasPrefix("@@") {
                lines.append(Line(kind: .skip, number: nil, text: ""))
            } else {
                let marker = row.first
                lines.append(Line(kind: kind(marker), number: nil, text: [" ", "+", "-"].contains(marker) ? String(row.dropFirst()) : row))
            }
        }
        return make(lines, incomplete: incomplete, files: files, requiresChange: files.isEmpty)
    }

    /// A unified diff for one file, as Codex reports it. A stat the runtime provides wins over counting.
    public static func unified(_ text: String, path: String, stat provided: Stat? = nil, truncated: Bool = false) -> ToolDiff? {
        var lines = [Line(kind: .file, number: nil, text: path)]
        var old = 0, new = 0, inHunk = false
        for row in rows(text) {
            if let match = row.wholeMatch(of: /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@.*/) {
                old = Int(match.1) ?? 0; new = Int(match.2) ?? 0; inHunk = true
                lines.append(Line(kind: .skip, number: nil, text: ""))
                continue
            }
            guard inHunk, let marker = row.first else { continue }
            switch marker {
            case "+": lines.append(Line(kind: .added, number: new, text: String(row.dropFirst()))); new += 1
            case "-": lines.append(Line(kind: .removed, number: old, text: String(row.dropFirst()))); old += 1
            case " ": lines.append(Line(kind: .context, number: new, text: String(row.dropFirst()))); old += 1; new += 1
            default: continue
            }
        }
        return make(lines, incomplete: truncated, files: [path], provided: provided, requiresChange: provided == nil)
    }

    /// Several files' diffs as one, as a Codex patch reports them. The stat needs every file's.
    public static func joined(_ diffs: [ToolDiff]) -> ToolDiff? {
        guard diffs.count > 1 else { return diffs.first }
        let stats = diffs.compactMap(\.stat)
        let stat = stats.count == diffs.count ? Stat(added: stats.reduce(0) { $0 + $1.added }, removed: stats.reduce(0) { $0 + $1.removed }) : nil
        var joined = ToolDiff(lines: diffs.flatMap(\.lines), stat: stat, files: diffs.flatMap(\.files))
        joined.isClipped = joined.isClipped || diffs.contains(where: \.isClipped)
        return joined
    }

    private static func rows(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.hasSuffix("\r") ? $0.dropLast() : $0) }
    }

    private static func kind(_ marker: Character?) -> LineKind {
        switch marker {
        case "+": .added
        case "-": .removed
        default: .context
        }
    }

    private static func make(_ lines: [Line], incomplete: Bool, files: [String], provided: Stat? = nil, requiresChange: Bool) -> ToolDiff? {
        let added = lines.lazy.filter { $0.kind == .added }.count
        let removed = lines.lazy.filter { $0.kind == .removed }.count
        guard added + removed > 0 || !requiresChange else { return nil }
        return ToolDiff(lines: lines, stat: provided ?? (incomplete ? nil : Stat(added: added, removed: removed)), files: files)
    }
}
