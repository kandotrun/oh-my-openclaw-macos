import Foundation

public struct ComposerDraft: Codable, Sendable, Equatable {
    public var text = ""
    public var attachments: [ChatAttachment] = []
    public init(text: String = "", attachments: [ChatAttachment] = []) { self.text = text; self.attachments = attachments }
}

public struct PendingSubmission: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var target: ChatSession
    public var params: JSONValue
    public var message: ChatMessage
    public var accepted: Bool
    public var draftRevisionAfterReservation: Int?
    public init(id: String, target: ChatSession, params: JSONValue, message: ChatMessage, accepted: Bool = false, draftRevisionAfterReservation: Int? = nil) {
        self.id = id; self.target = target; self.params = params; self.message = message; self.accepted = accepted
        self.draftRevisionAfterReservation = draftRevisionAfterReservation
    }
}

/// Durable, gateway-local conversation state. Transient activity is rebuilt from history.
public struct ConversationStore: Codable, Sendable {
    public var sessions: [ChatSession] = []
    public var selectedID: String?
    public var drafts: [String: ComposerDraft] = [:]
    public var transcripts: [String: [ChatMessage]] = [:]
    public var pending: [String: PendingSubmission] = [:]
    public var creationRequests: [String: JSONValue] = [:]
    public var creationIssuedAt: [String: Date]?
    public var activeRunIDs: [String: String] = [:]
    public var activities: [String: ActivityState] = [:]
    /// The last profile this Gateway named as the viewer, so saved rows stay on the right side while reconnecting.
    public var viewerProfileID: String?
    /// The person whose Cloudflare Access session last signed in to this Gateway, and so whose conversations
    /// these are. A service token or a shared token leaves it as it is; nil before anyone has signed in.
    public var accessOwner: CloudflareAccessAccount?
    private var runSequences: [String: Int] = [:]
    private var settledRunTargets: [String: ChatSession]?
    private var draftRevisions: [String: Int]?

    public init() {}
    public var selectedSession: ChatSession? { sessions.first { $0.id == selectedID } }
    public var selectedMessages: [ChatMessage] { selectedID.flatMap { transcripts[$0] } ?? [] }
    public var selectedDraft: ComposerDraft { selectedID.flatMap { drafts[$0] } ?? ComposerDraft() }

    public mutating func setDraft(_ draft: ComposerDraft, for id: String) {
        drafts[id] = draft
        if draftRevisions == nil { draftRevisions = [:] }
        let revision = (draftRevisions?[id] ?? 0) + 1
        draftRevisions?[id] = revision
    }

    public mutating func upsertSession(_ session: ChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let previous = sessions[index]
            sessions[index] = session
            if let old = previous.sessionID, let new = session.sessionID, old != new {
                transcripts[session.id] = []
                activeRunIDs[session.id] = nil
                activities[session.id] = .idle
                // Drafts and uncertain submissions belong to their original author/target.
                for key in pending.keys where pending[key]?.target.id == session.id {
                    pending[key]?.message.delivery = .uncertain
                }
            }
        } else { sessions.append(session) }
    }

    public mutating func replaceLocalSession(_ old: ChatSession, with new: ChatSession) {
        let draft = drafts.removeValue(forKey: old.id)
        let revision = draftRevisions?.removeValue(forKey: old.id)
        let transcript = transcripts.removeValue(forKey: old.id)
        sessions.removeAll { $0.id == old.id }
        creationRequests[old.id] = nil
        creationIssuedAt?[old.id] = nil
        upsertSession(new)
        if let draft { drafts[new.id] = draft }
        if let revision { draftRevisions?[new.id] = revision }
        if let transcript { transcripts[new.id] = transcript }
        if selectedID == old.id { selectedID = new.id }
    }

    public mutating func prepareSubmission(for session: ChatSession, policy: JSONValue) throws -> PendingSubmission {
        let draft = drafts[session.id] ?? ComposerDraft()
        guard unresolvedSubmission(matching: draft, for: session) == nil else {
            throw GatewayFailure(code: "UNRESOLVED_SEND", message: "このメッセージの送信結果を確認してから再試行してください。")
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty else {
            throw GatewayFailure(code: "EMPTY_MESSAGE", message: "メッセージを入力してください。")
        }
        let runID = UUID().uuidString
        var params: [String: JSONValue] = ["sessionKey": .string(session.key), "agentId": .string(session.agentID), "message": .string(draft.text), "idempotencyKey": .string(runID)]
        if let physicalID = session.sessionID { params["sessionId"] = .string(physicalID) }
        if !draft.attachments.isEmpty { params["attachments"] = .array(draft.attachments.map(\.wireValue)) }
        for attachment in draft.attachments {
            let limit = attachment.mimeType.hasPrefix("image/") ? policy["attachments"]["maxImageBytes"].intValue : policy["attachments"]["maxBytes"].intValue
            if let limit, attachment.data.count > limit {
                throw GatewayFailure(code: "ATTACHMENT_TOO_LARGE", message: "「\(attachment.fileName)」は接続先のサイズ上限を超えています。")
            }
        }
        let body = JSONValue.object(params)
        let frame = JSONValue.object(["type": .string("req"), "id": .string(UUID().uuidString), "method": .string("chat.send"), "params": body])
        let frameSize = try JSONEncoder().encode(frame).count
        if frameSize > (policy["maxPayload"].intValue ?? 25 * 1024 * 1024) {
            throw GatewayFailure(code: "PAYLOAD_TOO_LARGE", message: "添付ファイルの合計サイズが大きすぎます。ファイルを減らして送信してください。")
        }
        let message = ChatMessage(id: runID + ":user", role: .user, text: draft.text, attachments: draft.attachments, delivery: .pending, runID: runID, idempotencyKey: runID)
        // The durable outbox owns these bytes now; the composer is the next input.
        setDraft(ComposerDraft(), for: session.id)
        let submission = PendingSubmission(id: runID, target: session, params: body, message: message, draftRevisionAfterReservation: draftRevisions?[session.id])
        pending[runID] = submission
        transcripts[session.id, default: []].append(message)
        activeRunIDs[session.id] = runID
        activities[session.id] = .working
        return submission
    }

    public func unresolvedSubmission(matching draft: ComposerDraft, for session: ChatSession) -> PendingSubmission? {
        pending.values.first {
            $0.target.id == session.id && $0.target.sessionID == session.sessionID && !$0.accepted &&
            ComposerDraft(text: $0.message.text, attachments: $0.message.attachments) == draft
        }
    }

    /// A prepared input has not crossed the send boundary until its target is materialized.
    public mutating func materializeSubmission(_ id: String, as session: ChatSession) throws -> PendingSubmission {
        guard var submission = pending[id], submission.target.sessionID == nil,
              session.sessionID != nil, submission.target.agentID == session.agentID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "送信先の会話を確認できませんでした。")
        }
        let old = submission.target
        if old.id != session.id { replaceLocalSession(old, with: session) }
        else { upsertSession(session) }
        var body = submission.params.objectValue ?? [:]
        body["sessionKey"] = .string(session.key)
        body["sessionId"] = session.sessionID.map(JSONValue.string)
        submission.target = session; submission.params = .object(body)
        pending[id] = submission
        if !(transcripts[session.id] ?? []).contains(where: { $0.id == submission.message.id }) {
            transcripts[session.id, default: []].append(submission.message)
        }
        activeRunIDs[old.id] = nil; activities[old.id] = nil
        activeRunIDs[session.id] = id; activities[session.id] = .working
        return submission
    }

    public mutating func acknowledge(_ runID: String) {
        guard var submission = pending[runID] else { return }
        submission.accepted = true
        submission.message.delivery = .accepted
        pending[runID] = submission
        guard let current = sessions.first(where: { $0.id == submission.target.id }), current.sessionID == submission.target.sessionID else { return }
        if let index = transcripts[submission.target.id]?.firstIndex(where: { $0.id == runID + ":user" }) {
            transcripts[submission.target.id]?[index].delivery = .accepted
        }
        // Old snapshots retained the submitted draft until ACK. New reservations already
        // cleared it, so even an identically retyped next input must remain untouched.
        if ownsLegacyDraft(submission) { setDraft(ComposerDraft(), for: submission.target.id) }
    }

    public mutating func markUncertain(_ runID: String) {
        guard let submission = pending[runID] else { return }
        pending[runID]?.message.delivery = .uncertain
        if let index = transcripts[submission.target.id]?.firstIndex(where: { $0.runID == runID && $0.role == .user }) {
            transcripts[submission.target.id]?[index].delivery = .uncertain
        }
        if activeRunIDs[submission.target.id] == runID {
            activities[submission.target.id] = .idle
            activeRunIDs[submission.target.id] = nil
        }
    }

    public mutating func reject(_ runID: String) {
        guard var submission = pending[runID] else { return }
        let target = submission.target
        let original = ComposerDraft(text: submission.message.text, attachments: submission.message.attachments)
        let canRestore = submission.draftRevisionAfterReservation != nil &&
            draftRevisions?[target.id] == submission.draftRevisionAfterReservation &&
            (drafts[target.id] ?? ComposerDraft()) == ComposerDraft() &&
            sessions.first(where: { $0.id == target.id })?.sessionID == target.sessionID
        if canRestore {
            setDraft(original, for: target.id)
            pending[runID] = nil
            transcripts[target.id]?.removeAll { $0.id == runID + ":user" }
        } else if ownsLegacyDraft(submission) {
            // Legacy submissions still have their bytes in the composer.
            pending[runID] = nil
            transcripts[target.id]?.removeAll { $0.id == runID + ":user" }
        } else {
            // A newer draft owns the composer. Keep the failed input available to retry.
            submission.accepted = false; submission.message.delivery = .failed
            pending[runID] = submission
            if let index = transcripts[target.id]?.firstIndex(where: { $0.id == runID + ":user" }) {
                transcripts[target.id]?[index].delivery = .failed
            }
        }
        if activeRunIDs[submission.target.id] == runID {
            activities[submission.target.id] = .idle
            activeRunIDs[submission.target.id] = nil
        }
    }

    public func retrySubmission(_ id: String) throws -> PendingSubmission {
        let runID = id.hasSuffix(":user") ? String(id.dropLast(5)) : id
        guard let submission = pending[runID], let current = sessions.first(where: { $0.id == submission.target.id }),
              submission.target.sessionID == nil || current.sessionID == submission.target.sessionID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "会話の保存先が変わったため再送できません。元のメッセージを確認してください。")
        }
        return submission
    }

    public mutating func prepareRetry(_ id: String, consumingDraft: Bool = false) throws -> PendingSubmission {
        var submission = try retrySubmission(id)
        let original = ComposerDraft(text: submission.message.text, attachments: submission.message.attachments)
        if (consumingDraft && drafts[submission.target.id] == original) || ownsLegacyDraft(submission) {
            setDraft(ComposerDraft(), for: submission.target.id)
            submission.draftRevisionAfterReservation = draftRevisions?[submission.target.id]
        }
        submission.message.delivery = .pending
        pending[submission.id] = submission
        if let index = transcripts[submission.target.id]?.firstIndex(where: { $0.id == submission.message.id }) {
            transcripts[submission.target.id]?[index].delivery = .pending
        }
        return submission
    }

    private func ownsLegacyDraft(_ submission: PendingSubmission) -> Bool {
        let target = submission.target
        return submission.draftRevisionAfterReservation == nil &&
            draftRevisions?[target.id] == nil &&
            sessions.first(where: { $0.id == target.id })?.sessionID == target.sessionID &&
            drafts[target.id] == ComposerDraft(text: submission.message.text, attachments: submission.message.attachments)
    }

    /// Applies authoritative chat events once; agent text events must never enter this reducer.
    @discardableResult public mutating func applyChatEvent(_ payload: JSONValue) -> Bool {
        guard let key = payload["sessionKey"].stringValue, let runID = payload["runId"].stringValue,
              let session = matchingSession(key: key, agentID: payload["agentId"].stringValue) else { return false }
        let state = payload["state"].stringValue ?? ""
        let terminal = ["final", "aborted", "error"].contains(state)
        if let target = pending[runID]?.target ?? settledRunTargets?[runID], target.id != session.id || target.sessionID != session.sessionID {
            // The old receipt may settle, but its stream cannot mutate the replacement conversation.
            if terminal { acknowledge(runID) }
            return false
        }
        if let seq = payload["seq"].intValue {
            let sequenceKey = session.id + "|" + runID
            if let prior = runSequences[sequenceKey], seq <= prior { return false }
            runSequences[sequenceKey] = seq
        }
        if state == "status" {
            activeRunIDs[session.id] = runID; activities[session.id] = .working; return true
        }
        guard state == "delta" || terminal else { return false }
        let messageID = runID + ":assistant"
        var rows = transcripts[session.id] ?? []
        let index = rows.firstIndex { $0.id == messageID }
        var row = index.map { rows[$0] } ?? ChatMessage(id: messageID, role: .assistant, text: "", delivery: .pending, runID: runID)
        var internalSnapshot = false
        if payload.objectValue?["message"] != nil, payload["message"] != .null {
            let snapshot = Self.parseMessage(payload["message"], fallbackID: messageID)
            if snapshot.role == .assistant {
                row.text = snapshot.text
                row.attachments = snapshot.attachments
                row.sourceID = snapshot.sourceID
            } else {
                internalSnapshot = true
                if snapshot.isToolMessage == true, !snapshot.attachments.isEmpty {
                    for attachment in snapshot.attachments where !row.attachments.contains(where: { $0.id == attachment.id }) {
                        row.attachments.append(attachment)
                    }
                }
            }
        } else if state == "delta" {
            let delta = payload["deltaText"].stringValue ?? ""
            if payload["replace"].boolValue == true { row.text = delta } else { row.text += delta }
        }
        if terminal {
            row.delivery = state == "error" ? .failed : .complete
            if row.text.isEmpty, state == "error" { row.text = payload["errorMessage"].stringValue ?? "応答を完了できませんでした。" }
            if activeRunIDs[session.id] == runID { activeRunIDs[session.id] = nil; activities[session.id] = .idle }
            if pending[runID] != nil { acknowledge(runID) }
            if let userIndex = rows.firstIndex(where: { $0.id == runID + ":user" }) { rows[userIndex].delivery = .accepted }
        } else {
            activeRunIDs[session.id] = runID; activities[session.id] = internalSnapshot ? .working : .responding
        }
        if index != nil { rows[index!] = row }
        else if !row.text.isEmpty || !row.attachments.isEmpty { rows.append(row) }
        transcripts[session.id] = rows
        return true
    }

    @discardableResult public mutating func applyHistory(_ payload: JSONValue, for target: ChatSession, preservingOlderHistory: Bool = false) -> Int {
        guard let current = sessions.first(where: { $0.id == target.id }), current.sessionID == target.sessionID else { return 0 }
        if let serverID = payload["sessionId"].stringValue, let physical = target.sessionID, serverID != physical { return 0 }
        let previous = transcripts[target.id] ?? []
        let records = payload["messages"].arrayValue ?? []
        let receipts = payload["inputReceipts"].arrayValue ?? []
        let authoredIDs = Set(records.compactMap { $0["__openclaw"]["id"].stringValue ?? $0["id"].stringValue }.filter { !$0.isEmpty })
        var rows = Self.parseMessages(records, fallbackPrefix: "history").map { row in
            let prior = previous.first { old in
                guard old.role == row.role else { return false }
                if let key = row.idempotencyKey, Self.matchesSubmission(old, runID: key) { return true }
                guard let source = row.sourceID, authoredIDs.contains(source) else { return false }
                if old.id == row.id { return true }
                return receipts.contains { receipt in
                    guard receipt["consumedByEventId"].stringValue == source,
                          let runID = receipt["runId"].stringValue else { return false }
                    return Self.matchesSubmission(old, runID: runID)
                }
            }
            return prior.map { Self.retainingLocalAttachments(in: row, from: $0) } ?? row
        }
        var olderRows: [ChatMessage] = []
        if preservingOlderHistory, payload["hasMore"].boolValue == true, let firstID = rows.first?.id,
           let boundary = previous.firstIndex(where: { $0.id == firstID }) {
            olderRows = previous[..<boundary].filter { $0.sourceID != nil }
        }
        for item in payload["pendingInputs"]["items"].arrayValue ?? [] where item["message"] != .null {
            var row = Self.parseMessage(item["message"], fallbackID: item["id"].stringValue ?? UUID().uuidString)
            row.runID = item["runId"].stringValue
            // The pending projection intentionally strips message metadata; the outer
            // run ID identifies input custody, independently of its eventual execution.
            row.idempotencyKey = row.idempotencyKey ?? item["runId"].stringValue
            row.delivery = item["state"].stringValue == "cancelled" ? .failed : .accepted
            if row.delivery == .failed, let runID = row.runID, let submission = pending[runID],
               submission.target.id == target.id, submission.target.sessionID == target.sessionID {
                // The failed projection's Retry button addresses the durable local input.
                row.id = submission.message.id
            }
            let consumedEventID = row.runID.flatMap { runID in
                receipts.first { $0["runId"].stringValue == runID }?["consumedByEventId"].stringValue
            }
            if let key = row.idempotencyKey,
               let prior = previous.first(where: { Self.matchesSubmission($0, runID: key, consumedEventID: consumedEventID) }) {
                row = Self.retainingLocalAttachments(in: row, from: prior)
            }
            let alreadyProjected = (olderRows + rows).contains { existing in
                guard existing.role == row.role else { return false }
                if let source = row.sourceID, existing.sourceID == source { return true }
                guard row.role == .user, let key = row.idempotencyKey else { return false }
                return Self.matchesSubmission(existing, runID: key, consumedEventID: consumedEventID)
            }
            if !alreadyProjected { rows.append(row) }
        }
        var submissionOrder: [String: Int] = [:]
        for (index, row) in previous.enumerated() where row.role == .user {
            if let runID = row.runID, submissionOrder[runID] == nil { submissionOrder[runID] = index }
        }
        let unresolved = pending.values.filter { $0.target.id == target.id && $0.target.sessionID == target.sessionID }.sorted {
            let left = submissionOrder[$0.id] ?? Int.max, right = submissionOrder[$1.id] ?? Int.max
            return left == right ? $0.id < $1.id : left < right
        }
        for submission in unresolved {
            let receipt = receipts.first { $0["runId"].stringValue == submission.id }
            let consumedEventID = receipt?["consumedByEventId"].stringValue
            let matchingRows = (olderRows + rows).filter { Self.matchesSubmission($0, runID: submission.id, consumedEventID: consumedEventID) }
            for index in rows.indices where Self.matchesSubmission(rows[index], runID: submission.id, consumedEventID: consumedEventID) {
                rows[index] = Self.retainingLocalAttachments(in: rows[index], from: submission.message)
            }
            let storedRows = matchingRows.filter { $0.delivery != .failed }
            let stored = !storedRows.isEmpty
            let cancelled = receipt?["state"].stringValue == "cancelled" || matchingRows.contains { $0.delivery == .failed }
            if cancelled && !stored {
                pending[submission.id]?.accepted = false
                pending[submission.id]?.message.delivery = .failed
            } else if stored || ["pending", "consumed"].contains(receipt?["state"].stringValue ?? "") {
                acknowledge(submission.id)
                if stored {
                    // Receipt cleanup must not discard the physical fence for buffered events.
                    if settledRunTargets == nil { settledRunTargets = [:] }
                    settledRunTargets?[submission.id] = submission.target
                    for row in storedRows {
                        if let runID = row.runID { settledRunTargets?[runID] = submission.target }
                    }
                    // A custody projection is not yet the durable transcript row.
                    // Keep its input ID so the next refresh requests the receipt
                    // that bridges custody to the canonical message and its media.
                    if storedRows.contains(where: { $0.delivery == .complete }) {
                        pending[submission.id] = nil
                    }
                }
            }
            if matchingRows.isEmpty { rows.append(pending[submission.id]?.message ?? submission.message) }
        }
        let inflight = payload["inFlightRun"]
        if let runID = inflight["runId"].stringValue {
            // Execution ownership may differ from the submitted idempotency key.
            // Preserve its physical target after the input receipt is reconciled.
            if settledRunTargets == nil { settledRunTargets = [:] }
            settledRunTargets?[runID] = target
            // A refresh during the same run keeps the searching hint its live events set. An approval may have
            // been resolved by another client, and only a local answer clears that hint, so it is not kept.
            let searching = activeRunIDs[target.id] == runID && activities[target.id] == .searching
            activeRunIDs[target.id] = runID
            let text = inflight["text"].stringValue ?? ""
            activities[target.id] = searching ? .searching : text.isEmpty ? .working : .responding
            if !text.isEmpty { rows.append(ChatMessage(id: runID + ":assistant", role: .assistant, text: text, delivery: .pending, runID: runID)) }
        } else {
            activeRunIDs[target.id] = nil; activities[target.id] = .idle
        }
        transcripts[target.id] = olderRows + rows
        return olderRows.count
    }

    private static func matchesSubmission(_ row: ChatMessage, runID: String, consumedEventID: String? = nil) -> Bool {
        guard row.role == .user else { return false }
        if let consumedEventID, row.sourceID == consumedEventID { return true }
        if let key = row.idempotencyKey { return key == runID || key == runID + ":user" }
        return row.sourceID == runID + ":user"
    }

    /// History omits inline media bytes. Retain them only after the caller proves
    /// this is the same authored user message in the same physical conversation.
    private static func retainingLocalAttachments(in row: ChatMessage, from prior: ChatMessage) -> ChatMessage {
        guard row.role == .user, prior.role == .user, !prior.attachments.isEmpty else { return row }
        var result = row
        result.idempotencyKey = row.idempotencyKey ?? prior.idempotencyKey
        if result.attachments.isEmpty {
            result.attachments = prior.attachments
        } else {
            for index in result.attachments.indices where result.attachments[index].data.isEmpty {
                let attachment = result.attachments[index]
                let matching = prior.attachments.first { $0.id == attachment.id } ??
                    (result.attachments.count == prior.attachments.count ? prior.attachments[index] : nil)
                guard let matching, !matching.data.isEmpty,
                      attachment.mimeType == matching.mimeType ||
                        (attachment.mimeType.hasPrefix("image/") && matching.mimeType.hasPrefix("image/")) else { continue }
                result.attachments[index].data = matching.data
                if attachment.mimeType == "image/*" { result.attachments[index].mimeType = matching.mimeType }
            }
        }
        return result
    }

    public func matchingSession(key: String, agentID: String?) -> ChatSession? {
        let matches = sessions.filter { $0.key == key && (agentID == nil || $0.agentID == agentID) }
        return matches.count == 1 ? matches.first : nil
    }

    public static func parseMessage(_ value: JSONValue, fallbackID: String) -> ChatMessage {
        let content = ChatMessageContent.project(value, fallbackID: fallbackID)
        let metadata = value["__openclaw"]
        let id = metadata["id"].stringValue ?? value["id"].stringValue ?? fallbackID
        let runID = metadata["runId"].stringValue ?? value["runId"].stringValue
        let idempotencyKey = metadata["idempotencyKey"].stringValue ?? value["idempotencyKey"].stringValue
        return ChatMessage(id: id, role: content.role, text: content.text, attachments: content.attachments, runID: runID, sourceID: id, idempotencyKey: idempotencyKey, isToolMessage: content.isToolMessage ? true : nil,
                           sender: content.role == .user ? MessageSender.parse(value) : nil)
    }

    /// A durable record may project to several rows. Keep record identity apart from display identity.
    public static func parseMessages(_ values: [JSONValue], fallbackPrefix: String) -> [ChatMessage] {
        var siblings: [String: Int] = [:]
        return values.enumerated().map { index, value in
            var row = parseMessage(value, fallbackID: "\(fallbackPrefix):\(index)")
            let group = (row.sourceID ?? row.id) + "|" + row.role.rawValue
            let sibling = siblings[group, default: 0]
            siblings[group] = sibling + 1
            row.id = group + "|" + String(sibling)
            return row
        }
    }

    public mutating func retireTransientState() {
        activeRunIDs = [:]; activities = [:]; runSequences = [:]
        for runID in Array(pending.keys) { markUncertain(runID) }
    }
}
