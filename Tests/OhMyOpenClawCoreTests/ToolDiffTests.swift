import Testing
@testable import OhMyOpenClawCore

private func line(_ kind: ToolDiff.LineKind, _ number: Int?, _ text: String) -> ToolDiff.Line { ToolDiff.Line(kind: kind, number: number, text: text) }

@Suite("Tool diffs")
struct ToolDiffTests {
    @Test func numberedDiffKeepsLineNumbersAndCountsChanges() throws {
        let diff = try #require(ToolDiff.numbered(" 455 before\n-456 old\n+456 new"))
        #expect(diff.lines == [line(.context, 455, "before"), line(.removed, 456, "old"), line(.added, 456, "new")])
        #expect(diff.stat == ToolDiff.Stat(added: 1, removed: 1))
    }

    @Test func elidedRowsBecomeSkips() throws {
        let diff = try #require(ToolDiff.numbered("     ...\n+12 a\n     ..."))
        #expect(diff.lines == [line(.skip, nil, ""), line(.added, 12, "a"), line(.skip, nil, "")])
        #expect(diff.stat == ToolDiff.Stat(added: 1, removed: 0))
    }

    @Test func emptyChangedLinesKeepTheirNumber() throws {
        let diff = try #require(ToolDiff.numbered("+3 \n-4"))
        #expect(diff.lines == [line(.added, 3, ""), line(.removed, 4, "")])
    }

    @Test func aTruncatedDiffHasNoStat() throws {
        #expect(try #require(ToolDiff.numbered("+1 a\n...(truncated)...")).stat == nil)
        #expect(try #require(ToolDiff.numbered("+1 a", truncated: true)).stat == nil)
    }

    @Test func onlyTheStandaloneMarkerMeansTruncated() throws {
        let diff = try #require(ToolDiff.numbered("+3 note (truncated) here\n-4 x"))
        #expect(diff.lines.count == 2)
        #expect(diff.stat == ToolDiff.Stat(added: 1, removed: 1))
    }

    @Test func textThatIsNotADiffIsRejected() {
        #expect(ToolDiff.numbered("raw line") == nil)
        #expect(ToolDiff.numbered(" 1 a\n 2 b") == nil)
        #expect(ToolDiff.numbered("") == nil)
    }

    @Test func patchEnvelopeListsFilesAndChanges() throws {
        let diff = try #require(ToolDiff.patchEnvelope("*** Begin Patch\n*** Update File: src/app.ts\n@@\n-old\n+new\n*** End Patch"))
        #expect(diff.lines == [line(.file, nil, "src/app.ts"), line(.skip, nil, ""), line(.removed, nil, "old"), line(.added, nil, "new")])
        #expect(diff.stat == ToolDiff.Stat(added: 1, removed: 1))
        #expect(diff.files == ["src/app.ts"])
    }

    @Test func deletedFileHasNoCountableStat() throws {
        let diff = try #require(ToolDiff.patchEnvelope("*** Begin Patch\n*** Delete File: old.txt\n*** End Patch"))
        #expect(diff.stat == nil)
        #expect(diff.files == ["old.txt"])
    }

    @Test func movedFileShowsBothPaths() throws {
        let diff = try #require(ToolDiff.patchEnvelope("*** Begin Patch\n*** Update File: a\n*** Move to: b\n@@\n-x\n+y\n*** End Patch"))
        #expect(diff.lines.first == line(.file, nil, "a → b"))
    }

    @Test func somethingThatIsNotAPatchIsRejected() {
        #expect(ToolDiff.patchEnvelope("hello") == nil)
    }

    @Test func unifiedDiffNumbersLinesFromItsHunks() throws {
        let diff = try #require(ToolDiff.unified("--- a/x.swift\n+++ b/x.swift\n@@ -10,2 +10,2 @@\n keep\n-old\n+new", path: "x.swift"))
        #expect(diff.lines == [line(.file, nil, "x.swift"), line(.skip, nil, ""), line(.context, 10, "keep"), line(.removed, 11, "old"), line(.added, 11, "new")])
        #expect(diff.stat == ToolDiff.Stat(added: 1, removed: 1))
    }

    @Test func aProvidedStatWinsAndATruncatedUnifiedDiffHasNone() throws {
        let stated = try #require(ToolDiff.unified("@@ -1 +1 @@\n-a\n+b", path: "y", stat: ToolDiff.Stat(added: 7, removed: 3)))
        #expect(stated.stat == ToolDiff.Stat(added: 7, removed: 3))
        #expect(try #require(ToolDiff.unified("@@ -1 +1 @@\n-a\n+b", path: "y", truncated: true)).stat == nil)
    }

    @Test func veryLongDiffsAreClippedForDisplay() throws {
        let text = (1...500).map { "+\($0) line" }.joined(separator: "\n")
        let diff = try #require(ToolDiff.numbered(text))
        #expect(diff.lines.count == ToolDiff.maxLines)
        #expect(diff.isClipped)
        #expect(diff.stat == ToolDiff.Stat(added: 500, removed: 0))
    }
}
