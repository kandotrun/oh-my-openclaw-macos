import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue { objectValue?[key] ?? .null }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var intValue: Int? {
        guard let value = numberValue, value.isFinite, value >= Double(Int.min), value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
}

public struct GatewayCredentials: Codable, Sendable, Equatable {
    public var token: String?
    public var password: String?
    public var bootstrapToken: String?
    public var deviceToken: String?
    public var scopes: [String]?
    /// Sent with every request to a Gateway published behind Cloudflare Access.
    public var access: CloudflareAccessToken?
    /// A person's Cloudflare Access sign-in, which requests carry in place of `access`.
    public var accessSession: CloudflareAccessSession?
    public init(token: String? = nil, password: String? = nil, bootstrapToken: String? = nil, deviceToken: String? = nil, scopes: [String]? = nil,
                access: CloudflareAccessToken? = nil, accessSession: CloudflareAccessSession? = nil) {
        self.token = token; self.password = password; self.bootstrapToken = bootstrapToken
        self.deviceToken = deviceToken; self.scopes = scopes; self.access = access; self.accessSession = accessSession
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decodeIfPresent(String.self, forKey: .token)
        password = try values.decodeIfPresent(String.self, forKey: .password)
        bootstrapToken = try values.decodeIfPresent(String.self, forKey: .bootstrapToken)
        deviceToken = try values.decodeIfPresent(String.self, forKey: .deviceToken)
        scopes = try values.decodeIfPresent([String].self, forKey: .scopes)
        access = try values.decodeIfPresent(CloudflareAccessToken.self, forKey: .access)
        // A session that fails validation is dropped, so the rest of the saved item stays readable.
        accessSession = try? values.decodeIfPresent(CloudflareAccessSession.self, forKey: .accessSession)
    }

    private enum CodingKeys: String, CodingKey { case token, password, bootstrapToken, deviceToken, scopes, access, accessSession }
}

public struct GatewayHello: Sendable {
    public let payload: JSONValue
    public init(payload: JSONValue) { self.payload = payload }
    public var snapshot: JSONValue { payload["snapshot"] }
    public var policy: JSONValue { payload["policy"] }
}

public struct GatewayEvent: Sendable {
    public let name: String
    public let payload: JSONValue
    public let sequence: Int?
    public init(name: String, payload: JSONValue = .null, sequence: Int? = nil) {
        self.name = name; self.payload = payload; self.sequence = sequence
    }
}

public struct GatewayFailure: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue
    public init(code: String, message: String, details: JSONValue = .null) { self.code = code; self.message = message; self.details = details }
    public var errorDescription: String? { message }
}

public protocol GatewayServing: Sendable {
    func connect() async throws -> GatewayHello
    func request(method: String, params: JSONValue) async throws -> JSONValue
    func events() async -> AsyncStream<GatewayEvent>
    func disconnect() async
    func loadInboundMedia(_ reference: InboundMediaReference, session: ChatSession) async throws -> Data
}

extension GatewayServing {
    public func loadInboundMedia(_ reference: InboundMediaReference, session: ChatSession) async throws -> Data {
        throw GatewayFailure(code: "ATTACHMENT_UNAVAILABLE", message: "この接続では画像を取得できません。Gateway に再接続してください。")
    }
}
