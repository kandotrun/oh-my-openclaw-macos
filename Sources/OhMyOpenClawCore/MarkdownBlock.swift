import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String), heading(Int, String), bullet(String, String), quote(String), code(String, String)

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language = ""
        var fence: Fence?
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeFence = fence {
                if closesFence(line, fence: activeFence) { blocks.append(.code(language, code.joined(separator: "\n"))); code = []; fence = nil }
                else {
                    let spaces = min(activeFence.indentation, line.prefix(while: { $0 == " " }).count)
                    code.append(String(line.dropFirst(spaces)))
                }
                continue
            }
            if let opening = opensFence(line) {
                flushParagraph()
                fence = opening.0
                language = opening.1
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }), trimmed.distance(from: trimmed.startIndex, to: space) <= 6 {
                flushParagraph()
                blocks.append(.heading(trimmed.distance(from: trimmed.startIndex, to: space), String(trimmed[trimmed.index(after: space)...])))
            } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                blocks.append(.bullet("•", String(trimmed.dropFirst(2))))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(marker, String(trimmed[range.upperBound...])))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else { paragraph.append(line) }
        }
        flushParagraph()
        if fence != nil { blocks.append(.code(language, code.joined(separator: "\n"))) }
        return blocks
    }

    private struct Fence { let marker: Character; let count: Int; let indentation: Int }
    private static func fenceLine(_ line: String) -> Substring? {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return nil }
        return line.dropFirst(spaces)
    }
    private static func opensFence(_ line: String) -> (Fence, String)? {
        guard let candidate = fenceLine(line), let marker = candidate.first, marker == "`" || marker == "~" else { return nil }
        let count = candidate.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = String(candidate.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return (Fence(marker: marker, count: count, indentation: line.prefix(while: { $0 == " " }).count), info)
    }
    private static func closesFence(_ line: String, fence: Fence) -> Bool {
        guard let candidate = fenceLine(line) else { return false }
        let count = candidate.prefix(while: { $0 == fence.marker }).count
        return count >= fence.count && candidate.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
