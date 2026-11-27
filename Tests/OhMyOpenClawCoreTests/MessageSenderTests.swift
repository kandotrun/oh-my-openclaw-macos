import Foundation
import Testing
@testable import OhMyOpenClawCore

private func userRow(_ metadata: [String: JSONValue] = [:], extra: [String: JSONValue] = [:]) -> JSONValue {
    var row: [String: JSONValue] = ["role": .string("user"), "content": .string("hi")]
    if !metadata.isEmpty { row["__openclaw"] = .object(metadata) }
    row.merge(extra) { _, new in new }
    return .object(row)
}

private func profile(_ id: String) -> JSONValue { .object(["type": .string("profile"), "id": .string(id)]) }

@Suite("Message sender")
struct MessageSenderTests {
    @Test func profileSenderKeepsItsIdentityAndName() throws {
        let sender = try #require(MessageSender.parse(userRow([
            "senderId": .string("p2"), "senderName": .string("佐藤 花子"), "senderIdentity": profile("p2"),
            "senderProfileAvatarUrl": .string("/api/users/p2/avatar?v=3"),
        ])))
        #expect(sender.identityKind == "profile")
        #expect(sender.profileID == "p2")
        #expect(sender.displayName == "佐藤 花子")
        #expect(sender.colorSeed == "p2")
    }

    @Test func channelSenderIsAnObservationAndNeverAProfile() throws {
        let sender = try #require(MessageSender.parse(userRow([
            "senderId": .string("42"), "senderName": .string("Taro"), "senderUsername": .string("taro"),
            "senderIdentity": .object(["type": .string("observation"), "id": .string("42"), "pluginId": .string("telegram"),
                                       "accountId": .null, "senderKind": .string("human")]),
        ])))
        #expect(sender.identityKind == "observation")
        #expect(sender.identityID == "42")
        #expect(sender.profileID == nil)
        #expect(sender.displayName == "Taro")
    }

    @Test func remoteIdentityIsAccepted() throws {
        let sender = try #require(MessageSender.parse(userRow([
            "senderId": .string("U1"),
            "senderIdentity": .object(["type": .string("remote"), "id": .string("U1"), "pluginId": .string("slack"),
                                       "domain": .string("T1"), "idKind": .string("user")]),
        ])))
        #expect(sender.identityKind == "remote")
        #expect(sender.profileID == nil)
    }

    @Test(arguments: [
        JSONValue.object(["type": .string("agent"), "id": .string("main")]),
        .object(["type": .string("legacy"), "actorType": .string("human"), "source": .null, "id": .string("x")]),
        .object(["type": .string("profile"), "id": .string("  ")]),
        .object(["type": .string("profile"), "id": .string(String(repeating: "a", count: 513))]),
        .object(["type": .string("profile"), "id": .string("p2"), "extra": .string("x")]),
        .object(["type": .string("observation"), "id": .string("42"), "pluginId": .null, "accountId": .null, "senderKind": .string("robot")]),
        .object(["type": .string("observation"), "id": .string("42"), "pluginId": .string("telegram"), "senderKind": .string("human")]),
        .object(["type": .string("remote"), "id": .string("U1"), "pluginId": .string("slack"), "domain": .string(""), "idKind": .string("user")]),
        .string("profile:p2"),
    ])
    func unreadableIdentityIsDroppedButTheSenderStays(identity: JSONValue) throws {
        let sender = try #require(MessageSender.parse(userRow([
            "senderId": .string("p2"), "senderName": .string("Hana"), "senderIdentity": identity,
        ])))
        #expect(sender.identityKind == nil)
        #expect(sender.identityID == nil)
        #expect(sender.id == "p2")
        #expect(sender.name == "Hana")
    }

    @Test func labelLosesItsSessionSuffix() throws {
        let sender = try #require(MessageSender.parse(userRow(extra: [
            "senderLabel": .string(" Alice (0f8fad5b-d9cb-469f-a165-70867728950e) "),
        ])))
        #expect(sender.label == "Alice")
        #expect(sender.displayName == "Alice")
        #expect(sender.colorSeed == "Alice")
    }

    @Test func agentOpeningNamesTheAgent() throws {
        let sender = try #require(MessageSender.parse(userRow(["senderId": .string("agent:main")], extra: [
            "provenance": .object(["kind": .string("inter_session"), "sourceTool": .string("sessions_spawn"),
                                   "sourceSessionKey": .string("agent:main:dashboard:abc")]),
        ])))
        #expect(sender.agentID == "main")
    }

    @Test func otherInterSessionInputIsNotAnAgentOpening() {
        let row = userRow(extra: ["provenance": .object(["kind": .string("inter_session"), "sourceTool": .string("sessions_send"),
                                                         "sourceSessionKey": .string("agent:main:main")])])
        #expect(MessageSender.parse(row) == nil)
    }

    @Test func unattributedRowsHaveNoSender() {
        #expect(MessageSender.parse(userRow()) == nil)
        #expect(MessageSender.parse(userRow(["senderName": .string("   ")])) == nil)
    }

    @Test func emailShapedIdShowsItsLocalPart() throws {
        let sender = try #require(MessageSender.parse(userRow(["senderId": .string("hana@example.com")])))
        #expect(sender.displayName == "hana")
        #expect(sender.colorSeed == "hana@example.com")
    }
}

@Suite("Viewer identity")
struct ViewerIdentityTests {
    private func hello(connID: String?, presence: [JSONValue]) -> JSONValue {
        var server: [String: JSONValue] = ["version": .string("test")]
        if let connID { server["connId"] = .string(connID) }
        return .object(["server": .object(server), "snapshot": .object(["presence": .array(presence)])])
    }

    private func row(_ connection: String, user: JSONValue, reason: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["connectionId": .string(connection), "ts": .number(0), "user": user]
        if let reason { value["reason"] = .string(reason) }
        return .object(value)
    }

    private func user(_ id: String) -> JSONValue { .object(["id": .string(id), "identity": profile(id), "name": .string(id)]) }

    @Test func ownPresenceRowNamesTheViewer() {
        let payload = hello(connID: "c1", presence: [row("c0", user: user("p0")), row("c1", user: user("p1"))])
        #expect(ViewerIdentity.fromHello(payload) == .profile("p1"))
    }

    @Test func viewerStaysUnresolvedWithoutAnOwnProfileRow() {
        #expect(ViewerIdentity.fromHello(hello(connID: "c1", presence: [row("c1", user: user("p1"), reason: "disconnect")])) == .unresolved)
        #expect(ViewerIdentity.fromHello(hello(connID: "c1", presence: [row("c1", user: .object(["id": .string("alice")]))])) == .unresolved)
        #expect(ViewerIdentity.fromHello(hello(connID: nil, presence: [row("c1", user: user("p1"))])) == .unresolved)
        #expect(ViewerIdentity.fromHello(.object([:])) == .unresolved)
    }

    @Test func usersSelfNamesTheProfile() {
        let result: JSONValue = .object(["profile": .object(["id": .string("p1"), "displayName": .null, "emails": .array([]), "updatedAt": .number(1)])])
        #expect(ViewerIdentity.fromUsersSelf(result) == .profile("p1"))
        #expect(ViewerIdentity.fromUsersSelf(.object([:])) == .unresolved)
    }
}

@Suite("Sender in the store")
struct SenderStoreTests {
    private let session = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)

    @Test func userRowsCarryTheirSenderAndAssistantRowsDoNot() {
        let metadata: JSONValue = .object(["id": .string("m"), "senderId": .string("p2"), "senderName": .string("Hana"), "senderIdentity": profile("p2")])
        let user = ConversationStore.parseMessage(.object(["role": .string("user"), "content": .string("hi"), "__openclaw": metadata]), fallbackID: "u")
        let reply = ConversationStore.parseMessage(.object(["role": .string("assistant"), "content": .string("hello"), "__openclaw": metadata]), fallbackID: "a")
        #expect(user.sender?.profileID == "p2")
        #expect(reply.sender == nil)
    }

    @Test func queuedInputsCarryTheirSender() {
        var store = ConversationStore()
        store.upsertSession(session)
        store.applyHistory(.object([
            "sessionId": .string("physical"), "messages": .array([]),
            "pendingInputs": .object(["items": .array([.object([
                "id": .string("input-1"), "runId": .string("run-1"), "state": .string("pending"),
                "message": .object(["role": .string("user"), "content": .string("次はこれ"), "__openclaw": .object([
                    "senderId": .string("p2"), "senderName": .string("Hana"), "senderIdentity": profile("p2"),
                ])]),
            ])])]),
        ]), for: session)
        #expect(store.transcripts[session.id]?.first?.sender?.profileID == "p2")
    }

    @Test func storeSavedBeforeAttributionStillLoads() throws {
        let saved = """
        {"sessions":[{"key":"agent:a:main","agentID":"a","sessionID":"physical","title":"Main","isMain":true}],
         "selectedID":"a|agent:a:main","drafts":{},
         "transcripts":{"a|agent:a:main":[{"id":"m1","role":"user","text":"hi","attachments":[],"delivery":"complete"}]},
         "pending":{},"creationRequests":{},"activeRunIDs":{},"activities":{},"runSequences":{}}
        """
        let store = try JSONDecoder().decode(ConversationStore.self, from: Data(saved.utf8))
        #expect(store.transcripts["a|agent:a:main"]?.first?.sender == nil)
        #expect(store.viewerProfileID == nil)
    }

    @Test func savedSenderWithUnknownFieldsStillLoads() throws {
        let saved = """
        {"id":"m1","role":"user","text":"hi","attachments":[],"delivery":"complete",
         "sender":{"identityKind":"profile","identityID":"p2","name":"Hana","avatar":{"future":true}}}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(saved.utf8))
        #expect(message.sender?.profileID == "p2")
        let roundTrip = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(roundTrip == message)
    }

    @Test func savedSenderThatCannotBeReadDecodesAsEmpty() throws {
        let wrongType = """
        {"id":"m1","role":"user","text":"hi","attachments":[],"delivery":"complete","sender":{"identityKind":5,"name":"Hana"}}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(wrongType.utf8))
        #expect(message.sender?.identityKind == nil)
        #expect(message.sender?.name == "Hana")
        let notAnObject = """
        {"id":"m2","role":"user","text":"hi","attachments":[],"delivery":"complete","sender":"garbage"}
        """
        #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(notAnObject.utf8)).sender == MessageSender())
    }
}
