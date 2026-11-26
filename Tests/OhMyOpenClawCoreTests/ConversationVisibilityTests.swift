import Foundation
import Testing
@testable import OhMyOpenClawCore

private let visibilitySession = ChatSession(key: "agent:visible:main", agentID: "visible", sessionID: "physical", title: "Main")

private func visibilityEvent(_ state: String, message: JSONValue? = nil, delta: String? = nil) -> JSONValue {
    var value: [String: JSONValue] = [
        "sessionKey": .string(visibilitySession.key), "agentId": .string(visibilitySession.agentID),
        "runId": .string("execution"), "state": .string(state),
    ]
    if let message { value["message"] = message }
    if let delta { value["deltaText"] = .string(delta) }
    return .object(value)
}

@Suite("Conversation content visibility")
struct ConversationVisibilityTests {
    @Test func historyKeepsRecordCountButOnlyAuthoredConversationContentIsVisible() {
        let rows = ConversationStore.parseMessages([
            .object(["id": .string("user"), "role": .string("user"), "content": .array([
                .object(["type": .string("input_text"), "text": .string("調べてください")]),
            ])]),
            .object(["id": .string("assistant"), "role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string("確認します")]),
                .object(["type": .string("toolCall"), "name": .string("read"), "arguments": .object(["path": .string("internal-path")])]),
                .object(["type": .string("thinking"), "thinking": .string("internal reasoning")]),
            ])]),
            .object(["id": .string("result"), "role": .string("toolResult"), "toolCallId": .string("read-1"), "content": .array([
                .object(["type": .string("text"), "text": .string("{\"internalToolOutput\":true}")]),
            ])]),
            .object(["id": .string("envelope"), "role": .string("assistant"), "tool_name": .string("exec"), "content": .string("internal command output")]),
            .object(["id": .string("system"), "role": .string("system"), "content": .string("internal system context")]),
            .object(["id": .string("developer"), "role": .string("developer"), "content": .string("internal developer context")]),
            .object(["id": .string("call-only"), "role": .string("assistant"), "content": .array([
                .object(["type": .string("tool_use"), "name": .string("exec"), "input": .object(["command": .string("internal command")])]),
            ])]),
        ], fallbackPrefix: "history")
        #expect(rows.count == 7)
        #expect(rows.map(\.sourceID) == ["user", "assistant", "result", "envelope", "system", "developer", "call-only"])
        #expect(rows.filter(\.isConversationMessage).map(\.text) == ["調べてください", "確認します"])
        for row in rows[2...] {
            #expect(row.role == .system)
            #expect(row.text.isEmpty)
            #expect(row.attachments.isEmpty)
        }
    }

    @Test func conversationJSONAndCodeStayVisibleWithoutTextHeuristics() {
        let text = "```json\n{\"toolCallId\":\"example\",\"type\":\"input_text\"}\n```"
        for role in ["user", "assistant"] {
            let row = ConversationStore.parseMessage(.object(["role": .string(role), "content": .string(text)]), fallbackID: role)
            #expect(row.isConversationMessage)
            #expect(row.text == text)
        }
        let output = ConversationStore.parseMessage(.object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("output_text"), "text": .string("日本語の返信")]),
        ])]), fallbackID: "output")
        #expect(output.text == "日本語の返信")
    }

    @Test func finalAnswerPhaseReplacesIntermediateAssistantText() {
        let row = ConversationStore.parseMessage(.object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "phase": .string("analysis"), "text": .string("intermediate internal text")]),
            .object(["type": .string("text"), "phase": .string("final_answer"), "text": .string("確認できました")]),
        ])]), fallbackID: "answer")
        #expect(row.text == "確認できました")
    }

    @Test func toolSnapshotsPreservePriorPublicTextAndStillSettleTheExecution() throws {
        var store = ConversationStore()
        store.upsertSession(visibilitySession); store.selectedID = visibilitySession.id
        let started = store.applyChatEvent(visibilityEvent("delta", delta: "確認しています"))
        #expect(started)
        let tool: JSONValue = .object(["role": .string("toolResult"), "toolCallId": .string("exec-1"), "content": .array([
            .object(["type": .string("text"), "text": .string("{\"internalToolOutput\":true}")]),
        ])])
        let updated = store.applyChatEvent(visibilityEvent("delta", message: tool))
        #expect(updated)
        #expect(store.selectedMessages.filter(\.isConversationMessage).map(\.text) == ["確認しています"])
        #expect(store.activities[visibilitySession.id] == .working)
        let finished = store.applyChatEvent(visibilityEvent("final", message: tool))
        #expect(finished)
        #expect(store.selectedMessages.filter(\.isConversationMessage).map(\.text) == ["確認しています"])
        #expect(store.selectedMessages.first?.delivery == .complete)
        #expect(store.activeRunIDs[visibilitySession.id] == nil)
        let encoded = try JSONEncoder().encode(store)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("internalToolOutput"))
    }

    @Test func toolOnlyAssistantSnapshotsNeverBecomeAnEmptyOrRawBubble() {
        var store = ConversationStore()
        store.upsertSession(visibilitySession); store.selectedID = visibilitySession.id
        let envelope: JSONValue = .object(["role": .string("assistant"), "tool_use_id": .string("call-1"), "text": .string("internal result")])
        let updated = store.applyChatEvent(visibilityEvent("delta", message: envelope))
        #expect(updated)
        #expect(store.selectedMessages.filter(\.isConversationMessage).isEmpty)
        #expect(store.activities[visibilitySession.id] == .working)
        let finished = store.applyChatEvent(visibilityEvent("final", message: envelope))
        #expect(finished)
        #expect(store.selectedMessages.filter(\.isConversationMessage).isEmpty)
        #expect(store.activeRunIDs[visibilitySession.id] == nil)
    }

    @Test func orphanToolMediaRemainsUsableWithoutItsRawOutput() throws {
        let image: JSONValue = .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("AQID")])
        let document: JSONValue = .object(["type": .string("attachment"), "attachment": .object([
            "artifactId": .string("generated-document"), "kind": .string("document"), "label": .string("report.csv"),
            "mimeType": .string("text/csv"), "url": .string("/api/chat/media/outgoing/generated/full"),
        ])])
        let payload: JSONValue = .object(["role": .string("toolResult"), "toolCallId": .string("image-1"), "content": .array([
            .object(["type": .string("text"), "text": .string("raw generation output")]), image, document,
        ])])
        let row = ConversationStore.parseMessage(payload, fallbackID: "result")
        #expect(row.isConversationMessage)
        #expect(row.isToolMessage == true)
        #expect(row.text.isEmpty)
        #expect(row.attachments.count == 2)
        #expect(row.attachments.first?.data == Data([1, 2, 3]))
        #expect(row.attachments.last?.artifactID == "generated-document")
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(row))
        #expect(restored.isConversationMessage)
        #expect(restored.attachments == row.attachments)
        let nested = ConversationStore.parseMessage(.object(["role": .string("user"), "content": .array([
            .object(["type": .string("tool_result"), "tool_use_id": .string("call-1"), "content": .array([image])]),
        ])]), fallbackID: "nested")
        #expect(nested.isToolMessage == true)
        #expect(nested.text.isEmpty)
        #expect(nested.attachments.count == 1)
        #expect(nested.isConversationMessage)
        let hidden = ConversationStore.parseMessage(.object(["role": .string("toolResult"), "display": .bool(false), "content": .array([image])]), fallbackID: "hidden")
        #expect(!hidden.isConversationMessage)
        #expect(hidden.attachments.isEmpty)
        for hiddenMessage: JSONValue in [
            .object(["role": .string("system"), "toolCallId": .string("call-1"), "content": .array([image])]),
            .object(["role": .string("assistant"), "customType": .string("openclaw.runtime-context"), "content": .array([image])]),
            .object(["role": .string("user"), "provenance": .object(["kind": .string("internal_system")]), "content": .array([image])]),
        ] {
            let hidden = ConversationStore.parseMessage(hiddenMessage, fallbackID: "internal")
            #expect(!hidden.isConversationMessage)
            #expect(hidden.attachments.isEmpty)
        }
    }

    @Test func explicitDisplayContentOverridesRawContentAndCanBeEmpty() {
        for display: [JSONValue] in [[.object(["type": .string("text"), "text": .string("表示する返信")])], []] {
            let row = ConversationStore.parseMessage(.object([
                "role": .string("assistant"), "content": .string("raw hidden response"),
                "openclawDisplayContent": .array(display),
            ]), fallbackID: "display")
            #expect(row.text == (display.isEmpty ? "" : "表示する返信"))
        }
        let row = ConversationStore.parseMessage(.object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "textSignature": .string("{\"v\":1,\"phase\":\"analysis\"}"), "text": .string("intermediate")]),
            .object(["type": .string("text"), "textSignature": .string("{\"v\":1,\"phase\":\"final_answer\"}"), "text": .string("最終回答")]),
        ])]), fallbackID: "phase")
        #expect(row.text == "最終回答")
    }
}
