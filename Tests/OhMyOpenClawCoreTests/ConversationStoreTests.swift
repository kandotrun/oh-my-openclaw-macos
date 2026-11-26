import Foundation
import Testing
@testable import OhMyOpenClawCore

private let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical-main", title: "Main", isMain: true)
private let side = ChatSession(key: "agent:a:dashboard:side", agentID: "a", sessionID: "physical-side", title: "Side")

private func fixtureStore() -> ConversationStore {
    var store = ConversationStore()
    store.upsertSession(main); store.upsertSession(side); store.selectedID = main.id
    return store
}

private func chat(_ state: String, run: String = "run", session: ChatSession = main, seq: Int = 1, extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(extra.merging(["sessionKey": .string(session.key), "agentId": .string(session.agentID), "runId": .string(run), "state": .string(state), "seq": .number(Double(seq))], uniquingKeysWith: { _, new in new }))
}

@Test func conversationSnapshotAlreadyIncludesDeltaAndEmptyReplacementClearsText() {
    var store = fixtureStore()
    store.applyChatEvent(chat("delta", extra: ["deltaText": .string("Hello"), "message": .object(["role": .string("assistant"), "content": .string("Hello")])]))
    #expect(store.selectedMessages.last?.text == "Hello")
    store.applyChatEvent(chat("delta", seq: 8, extra: ["deltaText": .string(" world")]))
    #expect(store.selectedMessages.last?.text == "Hello world")
    store.applyChatEvent(chat("delta", seq: 9, extra: ["deltaText": .string(""), "replace": .bool(true)]))
    #expect(store.selectedMessages.last?.text == "")
    store.applyChatEvent(chat("delta", seq: 8, extra: ["deltaText": .string("stale")]))
    #expect(store.selectedMessages.last?.text == "")
}

@Test func conversationRunTargetsDoNotMixSideAndMain() {
    var store = fixtureStore()
    store.applyChatEvent(chat("delta", session: side, extra: ["deltaText": .string("side response")]))
    #expect(store.selectedMessages.isEmpty)
    #expect(store.transcripts[side.id]?.last?.text == "side response")
    store.applyChatEvent(chat("delta", run: "main-run", extra: ["deltaText": .string("main response")]))
    #expect(store.selectedMessages.last?.text == "main response")
    #expect(store.activeRunIDs[side.id] == "run")
}

@Test func conversationAcknowledgmentPreservesNewerTypedText() throws {
    var store = fixtureStore()
    let attachment = ChatAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
    store.setDraft(ComposerDraft(text: "original", attachments: [attachment]), for: main.id)
    let submission = try store.prepareSubmission(for: main, policy: .null)
    store.setDraft(ComposerDraft(text: "new Japanese input 日本語"), for: main.id)
    store.acknowledge(submission.id)
    #expect(store.selectedDraft.text == "new Japanese input 日本語")
    #expect(store.pending[submission.id]?.params == submission.params)
    #expect(store.pending[submission.id]?.message.attachments == [attachment])
}

@Test func conversationLostAcknowledgmentKeepsExactPayloadAcrossDiskAndRetry() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "one submission", attachments: [ChatAttachment(fileName: "x.zip", mimeType: "application/zip", data: Data([1, 2, 3]))]), for: side.id)
    let original = try store.prepareSubmission(for: side, policy: .null)
    store.markUncertain(original.id)
    let saved = try JSONEncoder().encode(store)
    var restored = try JSONDecoder().decode(ConversationStore.self, from: saved)
    let retry = try restored.retrySubmission(original.message.id)
    #expect(retry.id == original.id)
    #expect(retry.params == original.params)
    #expect(restored.drafts[side.id]?.text == "")
    #expect(restored.pending[original.id]?.message.text == "one submission")
    var replaced = side; replaced.sessionID = "new-physical-session"
    restored.upsertSession(replaced)
    #expect(throws: GatewayFailure.self) { try restored.retrySubmission(original.id) }
}

@Test func conversationAttachmentRejectionRetainsDraftAndCreatesNoOutbox() throws {
    var store = fixtureStore()
    let draft = ComposerDraft(text: "keep me", attachments: [ChatAttachment(fileName: "large.pdf", mimeType: "application/pdf", data: Data(repeating: 1, count: 64))])
    store.setDraft(draft, for: main.id)
    let policy: JSONValue = .object(["attachments": .object(["maxBytes": .number(10), "maxImageBytes": .number(10)])])
    #expect(throws: GatewayFailure.self) { try store.prepareSubmission(for: main, policy: policy) }
    #expect(store.selectedDraft == draft)
    #expect(store.pending.isEmpty)
    #expect(store.selectedMessages.isEmpty)
}

@Test func conversationTerminalBeforeAcknowledgmentSettlesUserDelivery() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "hello"), for: main.id)
    let submission = try store.prepareSubmission(for: main, policy: .null)
    store.applyChatEvent(chat("final", run: submission.id, extra: ["message": .object(["role": .string("assistant"), "content": .string("done")])]))
    #expect(store.selectedMessages.first?.delivery == .accepted)
    #expect(store.selectedDraft.text.isEmpty)
    #expect(store.activities[main.id] == .idle)
}

@Test func conversationHistoryReceiptsUseDurableIdentityAndSiblingRowsHaveDistinctIDs() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "hello"), for: main.id)
    let submission = try store.prepareSubmission(for: main, policy: .null)
    store.markUncertain(submission.id)
    let rows: [JSONValue] = [
        .object(["role": .string("user"), "content": .string("hello"), "__openclaw": .object(["id": .string("record-user")])]),
        .object(["role": .string("assistant"), "content": .string("first projected row"), "__openclaw": .object(["id": .string("record-assistant")])]),
        .object(["role": .string("assistant"), "content": .string("second projected row"), "__openclaw": .object(["id": .string("record-assistant")])]),
    ]
    store.applyHistory(.object(["sessionId": .string(main.sessionID!), "messages": .array(rows), "inputReceipts": .array([.object(["runId": .string(submission.id), "state": .string("consumed"), "consumedByEventId": .string("record-user")])])]), for: main)
    #expect(store.selectedMessages.count == 3)
    #expect(Set(store.selectedMessages.map(\.id)).count == 3)
    #expect(store.selectedMessages[1].sourceID == store.selectedMessages[2].sourceID)
    #expect(store.pending[submission.id] == nil)
    #expect(store.selectedDraft.text.isEmpty)
}

@Test func emptyHistoryWithoutReceiptEventIDsRetainsEveryUncertainSubmission() throws {
    var store = fixtureStore()
    var submitted: [PendingSubmission] = []
    for text in ["first unsent input", "second unsent input", "third unsent input"] {
        store.setDraft(ComposerDraft(text: text), for: main.id)
        let submission = try store.prepareSubmission(for: main, policy: .null)
        store.markUncertain(submission.id)
        submitted.append(submission)
    }
    store.applyHistory(.object(["sessionId": .string(main.sessionID!), "messages": .array([])]), for: main)
    #expect(store.pending.count == submitted.count)
    #expect(store.selectedMessages.count == submitted.count)
    #expect(store.selectedDraft.text.isEmpty)
    for submission in submitted {
        #expect(store.pending[submission.id]?.accepted == false)
        #expect(store.pending[submission.id]?.params == submission.params)
        #expect(store.selectedMessages.contains { $0.runID == submission.id && $0.delivery == .uncertain })
    }
}

@Test func uncertainSubmissionsKeepTheirOrderAcrossHistoryRefreshAndStoreReload() throws {
    var store = fixtureStore()
    let texts = (0..<10).map { "input \($0)" }
    for text in texts {
        store.setDraft(ComposerDraft(text: text), for: main.id)
        let submission = try store.prepareSubmission(for: main, policy: .null)
        store.markUncertain(submission.id)
    }
    var restored = try JSONDecoder().decode(ConversationStore.self, from: JSONEncoder().encode(store))
    for _ in 0..<2 {
        restored.applyHistory(.object(["sessionId": .string(main.sessionID!), "messages": .array([])]), for: main)
        #expect(restored.selectedMessages.map(\.text) == texts)
        #expect(restored.pending.count == texts.count)
    }
}

@Test func conversationHistoryCannotReplaceNewPhysicalSessionOrEraseDraft() {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "composing"), for: main.id)
    var replaced = main; replaced.sessionID = "replacement"
    store.upsertSession(replaced)
    store.applyHistory(.object(["sessionId": .string(main.sessionID!), "messages": .array([.object(["role": .string("assistant"), "content": .string("stale")])])]), for: main)
    #expect(store.selectedMessages.isEmpty)
    #expect(store.selectedDraft.text == "composing")
}

@Test func replacementHistoryDoesNotImportAnOlderPhysicalSubmission() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "original physical input"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    store.markUncertain(old.id)
    var replaced = main; replaced.sessionID = "replacement"
    store.upsertSession(replaced)
    store.applyHistory(.object(["sessionId": .string("replacement"), "messages": .array([])]), for: replaced)
    #expect(store.selectedMessages.isEmpty)
    #expect(store.pending[old.id]?.params == old.params)
    #expect(throws: GatewayFailure.self) { try store.retrySubmission(old.id) }
}

@Test func replacementSessionCanSubmitTheSameDraftWithoutReusingItsOldPhysicalIdentity() throws {
    var store = fixtureStore()
    let draft = ComposerDraft(text: "same draft", attachments: [ChatAttachment(fileName: "note.txt", mimeType: "text/plain", data: Data("note".utf8))])
    store.setDraft(draft, for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    store.markUncertain(old.id)
    #expect(store.unresolvedSubmission(matching: draft, for: main)?.id == old.id)
    var replacement = main; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    store.setDraft(draft, for: replacement.id)
    #expect(store.unresolvedSubmission(matching: draft, for: replacement) == nil)
    let new = try store.prepareSubmission(for: replacement, policy: .null)
    #expect(new.id != old.id)
    #expect(new.params["sessionId"].stringValue == "replacement")
    #expect(new.message.text == old.message.text)
    #expect(new.message.attachments == old.message.attachments)
    #expect(store.pending[old.id]?.params == old.params)
    #expect(throws: GatewayFailure.self) { try store.retrySubmission(old.id) }
}

@Test func bufferedEventsForAReplacedPhysicalSubmissionCannotRepopulateItsTranscript() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "original input"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    var replacement = main; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    for (index, state) in ["status", "delta", "final", "aborted", "error"].enumerated() {
        let applied = store.applyChatEvent(chat(state, run: old.id, seq: index + 1, extra: ["deltaText": .string("old response")]))
        #expect(!applied)
        #expect(store.selectedMessages.isEmpty)
        #expect(store.activeRunIDs[replacement.id] == nil)
        #expect(store.activities[replacement.id] == .idle)
        #expect(store.selectedDraft.text.isEmpty)
    }
    #expect(store.pending[old.id]?.accepted == true)
    #expect(store.pending[old.id]?.params == old.params)
}

@Test func bufferedOldEventsCannotReplaceTheNewPhysicalSessionsActiveRun() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "same input"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    var replacement = main; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    store.setDraft(ComposerDraft(text: "same input"), for: replacement.id)
    let current = try store.prepareSubmission(for: replacement, policy: .null)
    let currentRows = store.selectedMessages
    for (index, state) in ["status", "delta", "final"].enumerated() {
        store.applyChatEvent(chat(state, run: old.id, seq: index + 1, extra: ["deltaText": .string("old response")]))
        #expect(store.selectedMessages == currentRows)
        #expect(store.activeRunIDs[replacement.id] == current.id)
        #expect(store.activities[replacement.id] == .working)
        #expect(store.selectedDraft.text.isEmpty)
    }
    #expect(store.pending[old.id]?.accepted == true)
    #expect(store.pending[current.id]?.accepted == false)
}

@Test func settledRunKeepsItsPhysicalFenceAfterReceiptCleanupAndStoreReload() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "stored input"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    store.applyHistory(.object(["sessionId": .string(main.sessionID!), "messages": .array([
        .object(["role": .string("user"), "content": .string("stored input"), "runId": .string(old.id), "__openclaw": .object(["id": .string(old.id + ":user")])]),
    ])]), for: main)
    #expect(store.pending[old.id] == nil)
    let acceptedCurrentEvent = store.applyChatEvent(chat("delta", run: old.id, extra: ["deltaText": .string("current physical response")]))
    #expect(acceptedCurrentEvent)
    var restored = try JSONDecoder().decode(ConversationStore.self, from: JSONEncoder().encode(store))
    var replacement = main; replacement.sessionID = "replacement"
    restored.upsertSession(replacement)
    restored.setDraft(ComposerDraft(text: "replacement input"), for: replacement.id)
    let current = try restored.prepareSubmission(for: replacement, policy: .null)
    let currentRows = restored.selectedMessages
    for (index, state) in ["status", "delta", "final"].enumerated() {
        let applied = restored.applyChatEvent(chat(state, run: old.id, seq: index + 2, extra: ["deltaText": .string("old response")]))
        #expect(!applied)
        #expect(restored.selectedMessages == currentRows)
        #expect(restored.activeRunIDs[replacement.id] == current.id)
        #expect(restored.activities[replacement.id] == .working)
        #expect(restored.selectedDraft.text.isEmpty)
    }
    #expect(restored.pending[old.id] == nil)
}

@Test func settlingAnOldSubmissionCannotClearANewerActiveRun() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "A"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    store.markUncertain(old.id)
    store.setDraft(ComposerDraft(text: "B"), for: main.id)
    let running = try store.prepareSubmission(for: main, policy: .null)
    store.markUncertain(old.id)
    #expect(store.activeRunIDs[main.id] == running.id)
    #expect(store.activities[main.id] == .working)
}

@Test func oldAcknowledgmentCannotClearTheReplacementSessionsDraft() throws {
    var store = fixtureStore()
    store.setDraft(ComposerDraft(text: "same text"), for: main.id)
    let old = try store.prepareSubmission(for: main, policy: .null)
    var replacement = main; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    store.setDraft(ComposerDraft(text: "same text"), for: replacement.id)
    store.acknowledge(old.id)
    #expect(store.selectedDraft.text == "same text")
    #expect(store.pending[old.id]?.accepted == true)
}

@Test func materializationRestoresTheReservedInputAfterAnOverlappingHistoryRead() throws {
    var store = ConversationStore()
    let emptyMain = ChatSession(key: main.key, agentID: main.agentID, title: "Main", isMain: true)
    store.upsertSession(emptyMain); store.selectedID = emptyMain.id
    store.setDraft(ComposerDraft(text: "captured input"), for: emptyMain.id)
    let submission = try store.prepareSubmission(for: emptyMain, policy: .null)
    store.upsertSession(main)
    store.applyHistory(.object(["sessionId": .string(main.sessionID!), "messages": .array([])]), for: main)
    #expect(store.selectedMessages.isEmpty)
    let bound = try store.materializeSubmission(submission.id, as: main)
    #expect(store.selectedMessages.first?.id == submission.message.id)
    #expect(store.selectedMessages.first?.text == "captured input")
    #expect(bound.params["sessionId"].stringValue == main.sessionID)
}
