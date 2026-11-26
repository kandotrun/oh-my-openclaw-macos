import CryptoKit
import Foundation
import Testing
@testable import OhMyOpenClawCore

struct TransportIdentityTests {
    // RFC 8032 public test seed, never an installed device credential.
    private let seed = Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")

    @Test func proofMatchesIndependentNodeCryptoVector() throws {
        let identity = try DeviceIdentity(privateKeyData: seed)
        let credentials = GatewayCredentials(token: "shared-test-token")
        let scopes = ["operator.read", "operator.write"]
        let proof = try identity.deviceProof(nonce: "test-nonce", signedAt: 1_700_000_000_123, credentials: credentials, scopes: scopes)
        #expect(identity.deviceID == "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9")
        #expect(proof["publicKey"].stringValue == "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo")
        let expectedPayload = "v2|21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9|gateway-client|ui|operator|operator.read,operator.write|1700000000123|shared-test-token|test-nonce"
        #expect(identity.signaturePayload(nonce: "test-nonce", signedAt: 1_700_000_000_123, credentials: credentials, scopes: scopes) == expectedPayload)
        let publicKeyBytes = try #require(Data(base64URL: identity.publicKeyBase64URL))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        let signatureText = try #require(proof["signature"].stringValue)
        let signature = try #require(Data(base64URL: signatureText))
        #expect(publicKey.isValidSignature(signature, for: Data(expectedPayload.utf8)))
        // A precomputed independent node:crypto Ed25519 vector verifies the
        // canonical bytes. CryptoKit may randomize valid signature bytes.
        let nodeSignature = try #require(Data(base64URL: "Vq9WWa5_GVKJtU78_EB4zXy1hyNfpE9VPCFUHb6c5s-1FWv95TihjWxVH9DtUCTL5Np6bCBS-s-skc0utxx1DA"))
        #expect(publicKey.isValidSignature(nodeSignature, for: Data(expectedPayload.utf8)))
        #expect(proof["signedAt"].numberValue == 1_700_000_000_123)
        #expect(proof["nonce"].stringValue == "test-nonce")
        let restored = try DeviceIdentity(privateKeyData: identity.privateKeyData)
        #expect(restored.deviceID == identity.deviceID)
    }

    @Test func signatureSelectsWireTokenAndPreservesScopeOrder() throws {
        let identity = try DeviceIdentity(privateKeyData: seed)
        let scopes = ["operator.write", "operator.read"]
        let credentialCases: [(GatewayCredentials, String)] = [
            (.init(token: "shared", password: "ignored", bootstrapToken: "bootstrap", deviceToken: "device"), "shared"),
            (.init(password: "ignored", bootstrapToken: "bootstrap", deviceToken: "device"), "device"),
            (.init(bootstrapToken: "bootstrap"), "bootstrap"),
            (.init(password: "secret-password"), ""),
        ]
        for (credentials, expectedToken) in credentialCases {
            let payload = identity.signaturePayload(nonce: "n", signedAt: 123, credentials: credentials, scopes: scopes)
            #expect(payload == "v2|\(identity.deviceID)|gateway-client|ui|operator|operator.write,operator.read|123|\(expectedToken)|n")
            #expect(!payload.contains("secret-password"))
        }
    }

    @Test func changingNonceInvalidatesSignature() throws {
        let identity = try DeviceIdentity(privateKeyData: seed)
        let scopes = ["operator.read"]
        let proof = try identity.deviceProof(nonce: "first", signedAt: 123, credentials: .init(), scopes: scopes)
        let signatureText = try #require(proof["signature"].stringValue)
        let signature = try #require(Data(base64URL: signatureText))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64URL: identity.publicKeyBase64URL)!)
        let otherPayload = identity.signaturePayload(nonce: "other", signedAt: 123, credentials: .init(), scopes: scopes)
        #expect(!publicKey.isValidSignature(signature, for: Data(otherPayload.utf8)))
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
