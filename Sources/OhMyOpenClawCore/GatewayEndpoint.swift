import Foundation

public struct SetupCode: Sendable {
    public let url: URL
    public let bootstrapToken: String
    public let expiresAtMs: Double?
}

public enum GatewayEndpoint {
    /// HTTPS links are accepted as a convenience and retain the same secure origin.
    public static func parse(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var parts = URLComponents(string: value), let rawScheme = parts.scheme,
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil else {
            throw invalidURL()
        }
        switch rawScheme.lowercased() {
        case "https", "wss": parts.scheme = "wss"
        case "http", "ws": parts.scheme = "ws"
        default: throw invalidURL()
        }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if parts.scheme == "ws", !["localhost", "127.0.0.1", "::1"].contains(normalizedHost) {
            throw GatewayFailure(code: "INSECURE_URL", message: "リモート接続には wss:// の安全な Gateway URL を指定してください。")
        }
        parts.host = host.lowercased()
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url else { throw invalidURL() }
        return url
    }

    /// Shown when a setup code has expired, and its bootstrap token with it.
    public static let setupExpiredMessage = "セットアップコードの有効期限が切れています。新しいコードを発行してください。"

    /// The setup code's Gateway and bootstrap token, as of `now`: an expired code is refused.
    public static func decodeSetupCode(_ code: String, now: Date = Date()) throws -> SetupCode {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("oc-pair://") { value = String(value.dropFirst("oc-pair://".count)) }
        guard !value.isEmpty, value.count <= 32_768,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }),
              let data = Data(base64URL: value),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data), payload.objectValue != nil,
              let urlText = payload["url"].stringValue,
              let token = payload["bootstrapToken"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw invalidCode()
        }
        // Never silently discard a certificate trust condition in a setup payload.
        if payload.objectValue?["tlsFingerprint"] != nil {
            throw GatewayFailure(code: "TLS_PIN_UNSUPPORTED", message: "このセットアップコードには証明書ピンが必要です。現在はシステムが信頼する TLS 証明書の Gateway に接続してください。")
        }
        var expires: Double?
        if let raw = payload.objectValue?["expiresAtMs"] {
            guard let number = raw.numberValue, number.isFinite, number >= 0, number <= 9_007_199_254_740_991, number.rounded() == number else { throw invalidCode() }
            guard number > now.timeIntervalSince1970 * 1000 else {
                throw GatewayFailure(code: "SETUP_EXPIRED", message: setupExpiredMessage)
            }
            expires = number
        }
        return SetupCode(url: try parse(urlText), bootstrapToken: token, expiresAtMs: expires)
    }

    private static func invalidURL() -> GatewayFailure {
        GatewayFailure(code: "INVALID_URL", message: "wss:// で始まる Gateway URL を入力してください。認証情報や #、? は URL に含めず、認証欄を使ってください。")
    }
    private static func invalidCode() -> GatewayFailure {
        GatewayFailure(code: "INVALID_SETUP_CODE", message: "セットアップコードを確認してください。oc-pair:// から始まるコードも貼り付けできます。")
    }
}
