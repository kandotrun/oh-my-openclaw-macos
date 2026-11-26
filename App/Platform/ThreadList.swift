import Foundation
import OhMyOpenClawCore

/// Sidebar rows for the app shell. Project grouping arrives with the threads milestone.
enum ThreadList {
    /// Main sessions first, then the roster order, filtered by a case-insensitive title match.
    static func rows(_ sessions: [ChatSession], matching query: String) -> [ChatSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? sessions : sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        return matching.filter(\.isMain) + matching.filter { !$0.isMain }
    }
}
