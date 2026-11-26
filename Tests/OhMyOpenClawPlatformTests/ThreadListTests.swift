import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

private let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "m", title: "メインチャット", isMain: true)
private let build = ChatSession(key: "agent:a:build", agentID: "a", sessionID: "b", title: "Fix the CI build")
private let docs = ChatSession(key: "agent:a:docs", agentID: "a", sessionID: "d", title: "README の更新")

@Test func mainSessionsComeFirstAndTheRestKeepRosterOrder() {
    #expect(ThreadList.rows([build, main, docs], matching: "").map(\.key) == [main.key, build.key, docs.key])
}

@Test func queriesMatchTitlesCaseInsensitively() {
    #expect(ThreadList.rows([main, build, docs], matching: "ci BUILD").map(\.key) == [build.key])
    #expect(ThreadList.rows([main, build, docs], matching: "readme").map(\.key) == [docs.key])
}

@Test func blankQueriesKeepEveryThread() {
    #expect(ThreadList.rows([main, build, docs], matching: "  \n").count == 3)
}
