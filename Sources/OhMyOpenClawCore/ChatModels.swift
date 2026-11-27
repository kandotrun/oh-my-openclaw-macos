import Foundation

/// A Gateway media-store reference, bound to an explicit authored transcript record.
/// This is a locator, never a download credential or an arbitrary fetch URL.
public struct InboundMediaReference: Codable, Sendable, Equatable, Hashable {
    public let source: String
    public let messageID: String

    public init?(source: String, messageID: String) {
        guard source.utf8.count <= 4096, messageID.utf8.count <= 1024, !messageID.isEmpty,
              messageID.rangeOfCharacter(from: .controlCharacters) == nil,
              let parts = URLComponents(string: source),
              parts.scheme == "media", parts.host == "inbound", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.string == source,
              parts.percentEncodedPath.hasPrefix("/"), !parts.percentEncodedPath.hasPrefix("//") else { return nil }
        let id = String(parts.path.dropFirst())
        guard !id.isEmpty, id != ".", id != "..",
              !id.contains("/"), !id.contains("\\"), id.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.source = source; self.messageID = messageID
    }
}

public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var fileName: String
    public var mimeType: String
    public var data: Data
    public var artifactID: String?
    public var url: String?
    public var openURL: String?
    public var sizeBytes: Int?
    public var inboundMedia: InboundMediaReference?
    public init(id: String = UUID().uuidString, fileName: String, mimeType: String, data: Data, artifactID: String? = nil, url: String? = nil, openURL: String? = nil, sizeBytes: Int? = nil, inboundMedia: InboundMediaReference? = nil) {
        self.id = id; self.fileName = fileName; self.mimeType = mimeType; self.data = data
        self.artifactID = artifactID; self.url = url; self.openURL = openURL; self.sizeBytes = sizeBytes
        self.inboundMedia = inboundMedia
    }
    public var wireValue: JSONValue { .object(["fileName": .string(fileName), "mimeType": .string(mimeType), "content": .string(data.base64EncodedString()), "type": .string(mimeType.hasPrefix("image/") ? "image" : "file")]) }
}

public struct ChatSession: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var agentID: String
    public var sessionID: String?
    public var title: String
    public var isMain: Bool
    public var modelID: String?
    public var thinkingLevel: String?
    public var id: String { agentID + "|" + key }
    public init(key: String, agentID: String, sessionID: String? = nil, title: String, isMain: Bool = false, modelID: String? = nil, thinkingLevel: String? = nil) {
        self.key = key; self.agentID = agentID; self.sessionID = sessionID; self.title = title
        self.isMain = isMain; self.modelID = modelID; self.thinkingLevel = thinkingLevel
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, system }
    public enum Delivery: String, Codable, Sendable { case pending, accepted, uncertain, failed, complete }
    public var id: String
    public var role: Role
    public var text: String
    public var attachments: [ChatAttachment]
    public var delivery: Delivery
    public var runID: String?
    public var sourceID: String?
    public var idempotencyKey: String?
    public var isToolMessage: Bool?
    /// Who wrote a user row in a shared session. Assistant rows and local sends have none.
    public var sender: MessageSender?
    /// Internal history records retain their identity for paging and reconciliation,
    /// but only authored conversation content belongs in the transcript UI.
    public var isConversationMessage: Bool {
        if isToolMessage == true { return !attachments.isEmpty }
        return (role == .user || role == .assistant) && (!text.isEmpty || !attachments.isEmpty)
    }
    public init(id: String = UUID().uuidString, role: Role, text: String, attachments: [ChatAttachment] = [], delivery: Delivery = .complete, runID: String? = nil, sourceID: String? = nil, idempotencyKey: String? = nil, isToolMessage: Bool? = nil, sender: MessageSender? = nil) {
        self.id = id; self.role = role; self.text = text; self.attachments = attachments; self.delivery = delivery; self.runID = runID; self.sourceID = sourceID; self.idempotencyKey = idempotencyKey
        self.isToolMessage = isToolMessage; self.sender = sender
    }
}

public struct ThinkingLevel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct ModelOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var thinkingLevels: [ThinkingLevel]
    public init(id: String, name: String, thinkingLevels: [ThinkingLevel] = []) { self.id = id; self.name = name; self.thinkingLevels = thinkingLevels }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected, connecting, connected, pairing(requestID: String, message: String), failed(String)
}

public enum ActivityState: String, Codable, Sendable { case idle, working, searching, responding, waitingForApproval }

public struct ApprovalPrompt: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var detail: String
    public var choices: [String]
    public init(id: String, kind: String, title: String, detail: String, choices: [String]) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.choices = choices
    }
}
