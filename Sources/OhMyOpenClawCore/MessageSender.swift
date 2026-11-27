import Foundation

/// Who wrote a user row in a shared session, as the Gateway recorded it.
/// Every field is a plain optional string, so saved transcripts decode across versions.
public struct MessageSender: Codable, Sendable, Equatable, Hashable {
    /// The validated `senderIdentity` type: `profile`, `remote`, or `observation`.
    public var identityKind: String?
    /// The validated `senderIdentity` id.
    public var identityID: String?
    public var id: String?
    public var name: String?
    public var username: String?
    /// The top-level `senderLabel`, without a trailing session id.
    public var label: String?
    /// The agent that opened this session with `sessions_create` or `sessions_spawn`.
    public var agentID: String?

    public init(identityKind: String? = nil, identityID: String? = nil, id: String? = nil, name: String? = nil,
                username: String? = nil, label: String? = nil, agentID: String? = nil) {
        self.identityKind = identityKind; self.identityID = identityID; self.id = id; self.name = name
        self.username = username; self.label = label; self.agentID = agentID
    }

    /// Never throws: a saved sender that cannot be read becomes empty instead of making the saved store unreadable.
    public init(from decoder: any Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) -> String? { (try? fields?.decodeIfPresent(String.self, forKey: key)) ?? nil }
        self.init(identityKind: read(.identityKind), identityID: read(.identityID), id: read(.id), name: read(.name),
                  username: read(.username), label: read(.label), agentID: read(.agentID))
    }

    /// Only a profile identity can be the viewer; names and channel ids never are.
    public var profileID: String? { identityKind == "profile" ? identityID : nil }

    /// The Control UI's label order.
    public var displayName: String? { label ?? name ?? username ?? id.flatMap(Self.emailLocalPart) ?? id }

    /// The Control UI colors a person by their sender id, else by their label.
    public var colorSeed: String { id ?? displayName ?? "" }

    /// Reads `__openclaw` sender fields, the top-level `senderLabel`, and agent-opening provenance.
    public static func parse(_ record: JSONValue) -> MessageSender? {
        let metadata = record["__openclaw"]
        var sender = MessageSender(id: text(metadata["senderId"]), name: text(metadata["senderName"]),
                                   username: text(metadata["senderUsername"]),
                                   label: text(record["senderLabel"]).flatMap(withoutSessionSuffix),
                                   agentID: openingAgent(record["provenance"]))
        if let identity = identity(metadata["senderIdentity"]) {
            sender.identityKind = identity.kind; sender.identityID = identity.id
        }
        return sender == MessageSender() ? nil : sender
    }

    /// Mirrors the Gateway's reader: closed shapes with non-blank parts of at most 512 characters.
    private static func identity(_ value: JSONValue) -> (kind: String, id: String)? {
        guard let fields = value.objectValue, let kind = fields["type"]?.stringValue, let id = part(value["id"]) else { return nil }
        let keys = Set(fields.keys)
        switch kind {
        case "profile":
            guard keys == ["type", "id"] else { return nil }
        case "remote":
            guard keys == ["type", "id", "pluginId", "domain", "idKind"],
                  part(value["pluginId"]) != nil, part(value["domain"]) != nil, part(value["idKind"]) != nil else { return nil }
        case "observation":
            // `pluginId` and `accountId` are required keys whose value may be null.
            guard keys == ["type", "id", "pluginId", "accountId", "senderKind"],
                  ["human", "bot", "unknown"].contains(value["senderKind"].stringValue ?? ""),
                  value["pluginId"] == .null || part(value["pluginId"]) != nil,
                  value["accountId"] == .null || part(value["accountId"]) != nil else { return nil }
        default:
            return nil
        }
        return (kind, id)
    }

    private static func part(_ value: JSONValue) -> String? {
        guard let string = value.stringValue, text(value) != nil, string.utf16.count <= 512 else { return nil }
        return string
    }

    private static func text(_ value: JSONValue) -> String? {
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    private static func withoutSessionSuffix(_ label: String) -> String? {
        text(.string(label.replacing(/\s*\([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\)$/, with: "")))
    }

    private static func emailLocalPart(_ id: String) -> String? {
        id.wholeMatch(of: /([^@\s]+)@[^@\s]+/).map { String($0.1) }
    }

    private static func openingAgent(_ provenance: JSONValue) -> String? {
        guard provenance["kind"].stringValue == "inter_session",
              ["sessions_create", "sessions_spawn"].contains(provenance["sourceTool"].stringValue ?? ""),
              let key = provenance["sourceSessionKey"].stringValue else { return nil }
        let parts = key.split(separator: ":", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "agent", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }
}

/// Who "me" is on this connection. Only a profile can own messages.
public enum ViewerIdentity: Sendable, Equatable {
    case unresolved, profileless, profile(String)

    /// The caller's own `hello-ok` presence row names its profile, when it has one.
    public static func fromHello(_ payload: JSONValue) -> ViewerIdentity {
        guard let connection = payload["server"]["connId"].stringValue, !connection.isEmpty,
              let row = payload["snapshot"]["presence"].arrayValue?.first(where: {
                  $0["connectionId"].stringValue == connection && $0["reason"].stringValue != "disconnect"
              }),
              row["user"]["identity"]["type"].stringValue == "profile" else { return .unresolved }
        return profile(row["user"]["identity"]["id"])
    }

    public static func fromUsersSelf(_ result: JSONValue) -> ViewerIdentity { profile(result["profile"]["id"]) }

    private static func profile(_ id: JSONValue) -> ViewerIdentity {
        guard let id = id.stringValue, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unresolved }
        return .profile(id)
    }
}
