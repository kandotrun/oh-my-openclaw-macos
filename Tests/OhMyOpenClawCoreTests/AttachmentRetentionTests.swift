import Foundation
import Testing
@testable import OhMyOpenClawCore

private let photoSession = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Photos")
private let firstPhoto = ChatAttachment(id: "local:first", fileName: "first.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
private let secondPhoto = ChatAttachment(id: "local:second", fileName: "second.png", mimeType: "image/png", data: Data([4, 5, 6]))

private func photoStore() -> ConversationStore {
    var store = ConversationStore()
    store.upsertSession(photoSession)
    store.selectedID = photoSession.id
    return store
}

@Test func sentPhotoBytesSurviveCustodyCanonicalHistoryAndPersistedReload() throws {
    var store = photoStore()
    store.setDraft(ComposerDraft(text: "Two photos", attachments: [firstPhoto, secondPhoto]), for: photoSession.id)
    let submission = try store.prepareSubmission(for: photoSession, policy: .null)
    let omitted: [JSONValue] = [.object(["type": .string("text"), "text": .string("Two photos")])] +
        [firstPhoto, secondPhoto].map { _ in .object(["type": .string("image"), "omitted": .bool(true), "bytes": .number(3)]) }
    let custody: JSONValue = .object([
        "sessionId": .string("physical"), "messages": .array([]),
        "pendingInputs": .object(["items": .array([.object([
            "id": .string("pending:input"), "runId": .string(submission.id), "state": .string("pending"),
            "message": .object(["role": .string("user"), "content": .array(omitted), "__openclaw": .object(["id": .string("pending:input")])]),
        ])])]),
    ])
    store.applyHistory(custody, for: photoSession)
    #expect(store.selectedMessages.first?.attachments.map(\.data) == [firstPhoto.data, secondPhoto.data])
    // AppModel requests consumed-event receipts only while this input remains in
    // the outbox. Custody is accepted, but is not yet the durable transcript row.
    #expect(store.pending[submission.id]?.accepted == true)
    let canonical: JSONValue = .object([
        "sessionId": .string("physical"),
        "messages": .array([.object(["role": .string("user"), "content": .array(omitted), "__openclaw": .object(["id": .string("durable-photo-message")])])]),
        "inputReceipts": .array([.object(["runId": .string(submission.id), "state": .string("consumed"), "consumedByEventId": .string("durable-photo-message")])]),
    ])
    store.applyHistory(canonical, for: photoSession)
    #expect(store.pending[submission.id] == nil)
    #expect(store.selectedMessages.count == 1)
    #expect(store.selectedMessages.first?.attachments.map(\.data) == [firstPhoto.data, secondPhoto.data])
    store = try JSONDecoder().decode(ConversationStore.self, from: JSONEncoder().encode(store))
    store.applyHistory(canonical, for: photoSession)
    #expect(store.selectedMessages.first?.attachments.map(\.data) == [firstPhoto.data, secondPhoto.data])
}

@Test func canonicalPhotoKeepsAuthoritativeReferencesWhileRetainingLocalBytes() throws {
    var store = photoStore()
    store.setDraft(ComposerDraft(attachments: [firstPhoto]), for: photoSession.id)
    let submission = try store.prepareSubmission(for: photoSession, policy: .null)
    let history: JSONValue = .object([
        "sessionId": .string("physical"),
        "messages": .array([.object([
            "role": .string("user"), "__openclaw": .object(["id": .string("canonical")]),
            "content": .array([.object(["type": .string("image"), "artifactId": .string("artifact-id"), "url": .string("/api/artifacts/download/reference"), "mimeType": .string("image/jpeg"), "omitted": .bool(true)])]),
        ])]),
        "inputReceipts": .array([.object(["runId": .string(submission.id), "state": .string("consumed"), "consumedByEventId": .string("canonical")])]),
    ])
    store.applyHistory(history, for: photoSession)
    let attachment = try #require(store.selectedMessages.first?.attachments.first)
    #expect(attachment.artifactID == "artifact-id")
    #expect(attachment.url == "/api/artifacts/download/reference")
    #expect(attachment.data == firstPhoto.data)
    #expect(store.selectedMessages.first?.isConversationMessage == true)
}

@Test func photoRetentionRequiresAuthoredIdentityAndTheSamePhysicalSession() {
    var store = photoStore()
    store.transcripts[photoSession.id] = [
        ChatMessage(id: "history:0|user|0", role: .user, text: "same text", attachments: [firstPhoto], sourceID: "history:0"),
    ]
    let unanchored: JSONValue = .object(["sessionId": .string("physical"), "messages": .array([.object(["role": .string("user"), "content": .string("same text")])])])
    store.applyHistory(unanchored, for: photoSession)
    #expect(store.selectedMessages.first?.attachments.isEmpty == true)
    store.transcripts[photoSession.id] = [
        ChatMessage(id: "durable|user|0", role: .user, text: "same text", attachments: [firstPhoto], sourceID: "durable"),
    ]
    store.applyHistory(.object(["sessionId": .string("physical"), "messages": .array([.object([
        "role": .string("user"), "content": .string("same text"),
        "__openclaw": .object(["id": .string("a-different-message")]),
    ])])]), for: photoSession)
    #expect(store.selectedMessages.first?.attachments.isEmpty == true)
    store.transcripts[photoSession.id] = [
        ChatMessage(id: "durable|user|0", role: .user, text: "same text", attachments: [firstPhoto], sourceID: "durable"),
    ]
    store.applyHistory(.object(["sessionId": .string("physical"), "messages": .array([.object([
        "role": .string("user"), "content": .string("same text"), "display": .bool(false),
        "__openclaw": .object(["id": .string("durable")]),
    ])])]), for: photoSession)
    #expect(store.selectedMessages.first?.attachments.isEmpty == true)
    #expect(store.selectedMessages.first?.isConversationMessage == false)
    store.transcripts[photoSession.id] = [
        ChatMessage(id: "durable|user|0", role: .user, text: "same text", attachments: [firstPhoto], sourceID: "durable"),
    ]
    var replacement = photoSession
    replacement.sessionID = "replacement"
    store.upsertSession(replacement)
    store.applyHistory(.object(["sessionId": .string("replacement"), "messages": .array([.object([
        "role": .string("user"), "content": .string("same text"), "__openclaw": .object(["id": .string("durable")]),
    ])])]), for: replacement)
    #expect(store.selectedMessages.first?.attachments.isEmpty == true)
}
