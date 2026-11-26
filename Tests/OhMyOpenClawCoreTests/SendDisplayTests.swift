import Foundation
import Testing
@testable import OhMyOpenClawCore

private let displaySession = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)

private func displayStore(_ draft: ComposerDraft = ComposerDraft(text: "same input")) -> ConversationStore {
    var store = ConversationStore()
    store.upsertSession(displaySession); store.selectedID = displaySession.id
    store.setDraft(draft, for: displaySession.id)
    return store
}

private func userProjection(eventID: String, key: String, runID: String? = nil) -> JSONValue {
    var metadata: [String: JSONValue] = ["id": .string(eventID), "idempotencyKey": .string(key)]
    if let runID { metadata["runId"] = .string(runID) }
    return .object(["role": .string("user"), "content": .string("same input"), "__openclaw": .object(metadata)])
}

@Test func reservationMovesTextAndAttachmentsIntoOneDurableBubble() throws {
    let attachment = ChatAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("note".utf8))
    var store = displayStore(ComposerDraft(text: "same input", attachments: [attachment]))
    let sent = try store.prepareSubmission(for: displaySession, policy: .null)
    #expect(store.selectedDraft == ComposerDraft())
    #expect(store.selectedMessages.map(\.id) == [sent.message.id])
    let restored = try JSONDecoder().decode(ConversationStore.self, from: JSONEncoder().encode(store))
    #expect(restored.selectedDraft == ComposerDraft())
    #expect(restored.pending[sent.id]?.message.attachments == [attachment])
    #expect(restored.pending[sent.id]?.params == sent.params)
}

@Test func canonicalIdempotencyEchoAndPendingProjectionReplaceOnlyTheOptimisticInput() throws {
    var store = displayStore()
    let sent = try store.prepareSubmission(for: displaySession, policy: .null)
    store.setDraft(ComposerDraft(text: "same input"), for: displaySession.id)
    store.applyHistory(.object([
        "sessionId": .string("physical"),
        "messages": .array([userProjection(eventID: "canonical-user", key: sent.id + ":user", runID: "execution-owner")]),
        "pendingInputs": .object(["items": .array([.object([
            "id": .string("custody-input"), "runId": .string(sent.id), "state": .string("pending"),
            "message": .object(["role": .string("user"), "content": .string("same input"), "__openclaw": .object(["id": .string("pending:custody-input")])]),
        ])])]),
        "inFlightRun": .object(["runId": .string("execution-owner"), "text": .string("")]),
    ]), for: displaySession)
    #expect(store.selectedMessages.filter { $0.role == .user }.count == 1)
    #expect(store.selectedMessages.first?.sourceID == "canonical-user")
    #expect(store.pending[sent.id] == nil)
    #expect(store.activeRunIDs[displaySession.id] == "execution-owner")
    store.acknowledge(sent.id)
    #expect(store.activeRunIDs[displaySession.id] == "execution-owner")
    #expect(store.selectedDraft.text == "same input")
    var replacement = displaySession; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    let appliedOldEvent = store.applyChatEvent(.object([
        "sessionKey": .string(replacement.key), "agentId": .string(replacement.agentID),
        "runId": .string("execution-owner"), "state": .string("delta"), "deltaText": .string("old response"),
    ]))
    #expect(!appliedOldEvent)
    #expect(store.selectedMessages.isEmpty)
}

@Test func canonicalRowsWithEqualTextAndExecutionOwnerKeepDistinctSubmissionIdentity() throws {
    var store = displayStore()
    let sent = try store.prepareSubmission(for: displaySession, policy: .null)
    store.markUncertain(sent.id)
    store.applyHistory(.object([
        "sessionId": .string("physical"),
        "messages": .array([userProjection(eventID: "another-user", key: "different-input", runID: sent.id)]),
    ]), for: displaySession)
    #expect(store.selectedMessages.filter { $0.role == .user }.count == 2)
    #expect(store.pending[sent.id] != nil)
    store.applyHistory(.object([
        "sessionId": .string("physical"),
        "messages": .array([
            userProjection(eventID: "another-user", key: "different-input", runID: sent.id),
            userProjection(eventID: "own-user", key: sent.id, runID: "another-execution"),
        ]),
    ]), for: displaySession)
    #expect(store.selectedMessages.filter { $0.role == .user }.count == 2)
    #expect(store.pending[sent.id] == nil)
}

@Test func consumedReceiptDeduplicatesStaleCustodyWithoutMergingTheNextIdenticalSend() throws {
    for hasConsumedEventID in [true, false] {
        var store = displayStore()
        let first = try store.prepareSubmission(for: displaySession, policy: .null)
        store.acknowledge(first.id)
        store.setDraft(ComposerDraft(text: "same input"), for: displaySession.id)
        let next = try store.prepareSubmission(for: displaySession, policy: .null)
        let canonical: JSONValue = .object([
            "role": .string("user"), "content": .string("same input"),
            "__openclaw": .object(["id": .string("canonical-user")]),
        ])
        func custody(_ submission: PendingSubmission, eventID: String) -> JSONValue {
            .object([
                "id": .string(eventID), "runId": .string(submission.id), "state": .string("pending"),
                "message": .object([
                    "role": .string("user"), "content": .string("same input"),
                    "__openclaw": .object(["id": .string(eventID)]),
                ]),
            ])
        }
        var receipt: [String: JSONValue] = ["runId": .string(first.id), "state": .string("consumed")]
        if hasConsumedEventID { receipt["consumedByEventId"] = .string("canonical-user") }
        // Pending custody can be read before consumption, followed by newer receipts
        // and canonical history. Equal text in the next send has a separate identity.
        let history: JSONValue = .object([
            "sessionId": .string("physical"), "messages": .array([canonical]),
            "pendingInputs": .object(["items": .array([
                custody(first, eventID: "pending:first"), custody(next, eventID: "pending:next"),
            ])]),
            "inputReceipts": .array([.object(receipt), .object([
                "runId": .string(next.id), "state": .string("pending"),
            ])]),
        ])
        store.applyHistory(history, for: displaySession)
        store.applyHistory(history, for: displaySession)
        let rows = store.selectedMessages.filter { $0.role == .user }
        #expect(rows.map(\.sourceID) == (hasConsumedEventID
            ? ["canonical-user", "pending:next"]
            : ["canonical-user", "pending:first", "pending:next"]))
        #expect(rows.filter { $0.idempotencyKey == next.id }.count == 1)
        #expect(rows.allSatisfy { $0.text == "same input" })
    }
}

@Test func pendingCustodyProjectionReplacesTheLocalBubbleWithoutAReceipt() throws {
    var store = displayStore()
    let sent = try store.prepareSubmission(for: displaySession, policy: .null)
    store.applyHistory(.object([
        "sessionId": .string("physical"), "messages": .array([]),
        "pendingInputs": .object(["items": .array([.object([
            "id": .string("custody-input"), "runId": .string(sent.id), "state": .string("pending"),
            "message": .object(["role": .string("user"), "content": .string("same input"), "__openclaw": .object(["id": .string("pending:custody-input")])]),
        ])])]),
    ]), for: displaySession)
    #expect(store.selectedMessages.filter { $0.role == .user }.count == 1)
    #expect(store.selectedMessages.first?.sourceID == "pending:custody-input")
}

@Test func completedExecutionRemainsFencedAfterItsInputIsReconciledAndPersisted() throws {
    var store = displayStore()
    let sent = try store.prepareSubmission(for: displaySession, policy: .null)
    store.applyHistory(.object([
        "sessionId": .string("physical"),
        "messages": .array([userProjection(eventID: "canonical-user", key: sent.id, runID: "completed-execution")]),
    ]), for: displaySession)
    #expect(store.pending[sent.id] == nil)
    store = try JSONDecoder().decode(ConversationStore.self, from: JSONEncoder().encode(store))
    var replacement = displaySession; replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    for state in ["status", "delta", "final"] {
        let applied = store.applyChatEvent(.object([
            "sessionKey": .string(replacement.key), "agentId": .string(replacement.agentID),
            "runId": .string("completed-execution"), "state": .string(state), "deltaText": .string("old response"),
        ]))
        #expect(!applied)
        #expect(store.selectedMessages.isEmpty)
        #expect(store.activeRunIDs[replacement.id] == nil)
    }
}

@Test func cancelledCustodyKeepsOneFailedBubbleWithItsOriginalRetryAndNewerDraft() throws {
    for includesProjection in [true, false] {
        var store = displayStore()
        let sent = try store.prepareSubmission(for: displaySession, policy: .null)
        store.setDraft(ComposerDraft(text: "next input"), for: displaySession.id)
        let item: JSONValue = .object([
            "id": .string("cancelled-custody"), "runId": .string(sent.id), "state": .string("cancelled"),
            "message": .object(["role": .string("user"), "content": .string("same input"), "__openclaw": .object(["id": .string("pending:cancelled-custody")])]),
        ])
        let history: JSONValue = .object([
            "sessionId": .string("physical"), "messages": .array([]),
            "pendingInputs": .object(["items": .array(includesProjection ? [item] : [])]),
            "inputReceipts": .array([.object(["runId": .string(sent.id), "state": .string("cancelled")])]),
        ])
        store.applyHistory(history, for: displaySession)
        store.applyHistory(history, for: displaySession)
        store = try JSONDecoder().decode(ConversationStore.self, from: JSONEncoder().encode(store))
        #expect(store.pending[sent.id]?.accepted == false)
        #expect(store.pending[sent.id]?.message.delivery == .failed)
        #expect(store.selectedMessages.count == 1)
        let row = try #require(store.selectedMessages.first)
        #expect(row.id == sent.message.id)
        #expect(row.delivery == .failed)
        let retry = try store.prepareRetry(row.id)
        #expect(retry.params == sent.params)
        #expect(store.selectedMessages.first?.delivery == .pending)
        #expect(store.selectedDraft.text == "next input")
    }
}

@Test func definitiveRejectionRestoresOnlyAnUntouchedEmptyComposer() throws {
    var untouched = displayStore()
    let first = try untouched.prepareSubmission(for: displaySession, policy: .null)
    untouched.reject(first.id)
    #expect(untouched.selectedDraft.text == "same input")
    #expect(untouched.selectedMessages.isEmpty)
    #expect(untouched.pending[first.id] == nil)

    var edited = displayStore()
    let second = try edited.prepareSubmission(for: displaySession, policy: .null)
    edited.setDraft(ComposerDraft(text: "new draft"), for: displaySession.id)
    edited.reject(second.id)
    #expect(edited.selectedDraft.text == "new draft")
    #expect(edited.pending[second.id]?.message.delivery == .failed)
    #expect(try edited.retrySubmission(second.id).params == second.params)

    var cleared = displayStore()
    let third = try cleared.prepareSubmission(for: displaySession, policy: .null)
    cleared.setDraft(ComposerDraft(text: "new draft"), for: displaySession.id)
    cleared.setDraft(ComposerDraft(), for: displaySession.id)
    cleared.reject(third.id)
    #expect(cleared.selectedDraft == ComposerDraft())
    #expect(cleared.pending[third.id]?.message.delivery == .failed)
}

@Test func preReservationSnapshotsStillDecodeAndKeepTheirRetryIdentity() throws {
    var store = displayStore()
    let sent = try store.prepareSubmission(for: displaySession, policy: .null)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
    object.removeValue(forKey: "draftRevisions")
    var pending = try #require(object["pending"] as? [String: [String: Any]])
    pending[sent.id]?.removeValue(forKey: "draftRevisionAfterReservation")
    if var message = pending[sent.id]?["message"] as? [String: Any] {
        message.removeValue(forKey: "idempotencyKey")
        pending[sent.id]?["message"] = message
    }
    object["pending"] = pending
    object["drafts"] = [displaySession.id: ["text": "same input", "attachments": []]]
    var restored = try JSONDecoder().decode(ConversationStore.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(try restored.retrySubmission(sent.id).params == sent.params)
    var edited = restored
    edited.setDraft(ComposerDraft(text: "same input"), for: displaySession.id)
    edited.acknowledge(sent.id)
    #expect(edited.selectedDraft.text == "same input")
    var rejected = restored
    rejected.setDraft(ComposerDraft(text: "same input"), for: displaySession.id)
    rejected.reject(sent.id)
    #expect(rejected.selectedDraft.text == "same input")
    #expect(rejected.pending[sent.id]?.message.delivery == .failed)
    restored.acknowledge(sent.id)
    #expect(restored.selectedDraft == ComposerDraft())
}
