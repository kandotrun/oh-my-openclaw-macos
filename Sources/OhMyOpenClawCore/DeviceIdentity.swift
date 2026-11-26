import CryptoKit
import Foundation

/// Stable per-install identity. Persist `privateKeyData` in the app's Keychain.
public struct DeviceIdentity: Sendable {
    private let key: Curve25519.Signing.PrivateKey

    public init() { key = Curve25519.Signing.PrivateKey() }
    public init(privateKeyData: Data) throws { key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) }
    public var privateKeyData: Data { key.rawRepresentation }
    public var deviceID: String { SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined() }
    public var publicKeyBase64URL: String { key.publicKey.rawRepresentation.base64URL }

    // Adapted from OpenClaw's MIT-licensed DeviceAuthPayload.swift at a8a7ce9.
    // Copyright (c) OpenClaw Foundation. See THIRD_PARTY_NOTICES.md.
    // v2 deliberately follows the official Apple client's compatibility signer.
    public func signaturePayload(nonce: String, signedAt: Int64, credentials: GatewayCredentials, scopes: [String]) -> String {
        ["v2", deviceID, "gateway-client", "ui", "operator", scopes.joined(separator: ","), String(signedAt), Self.signatureToken(credentials), nonce].joined(separator: "|")
    }

    public func deviceProof(nonce: String, signedAt: Int64, credentials: GatewayCredentials, scopes: [String]) throws -> JSONValue {
        let payload = signaturePayload(nonce: nonce, signedAt: signedAt, credentials: credentials, scopes: scopes)
        return .object([
            "id": .string(deviceID), "publicKey": .string(publicKeyBase64URL),
            "signature": .string(try key.signature(for: Data(payload.utf8)).base64URL),
            "signedAt": .number(Double(signedAt)), "nonce": .string(nonce),
        ])
    }

    static func signatureToken(_ credentials: GatewayCredentials) -> String {
        credentials.token ?? credentials.deviceToken ?? credentials.bootstrapToken ?? ""
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let base = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
