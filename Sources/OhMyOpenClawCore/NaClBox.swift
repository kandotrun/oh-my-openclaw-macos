import CryptoKit
import Foundation
internal import CTweetNaCl

public enum NaClBoxError: Error, Equatable, Sendable {
    case messageTooShort
    case invalidSenderKey
    case authenticationFailed
}

/// Opens NaCl `crypto_box` messages laid out as `nonce (24) || tag (16) || ciphertext`,
/// matching golang.org/x/crypto/nacl/box.Open on the bytes after the nonce.
public enum NaClBox {
    public static let nonceByteCount = 24
    public static let tagByteCount = 16
    static let boxZeroByteCount = 16 // crypto_box_BOXZEROBYTES
    static let zeroByteCount = 32 // crypto_box_ZEROBYTES
    static let sigma = Array("expand 32-byte k".utf8)

    public static func open(
        noncePrefixed data: Data,
        from sender: Curve25519.KeyAgreement.PublicKey,
        using recipient: Curve25519.KeyAgreement.PrivateKey
    ) throws(NaClBoxError) -> Data {
        guard data.count >= nonceByteCount + tagByteCount else { throw .messageTooShort }
        let shared: SharedSecret
        do { shared = try recipient.sharedSecretFromKeyAgreement(with: sender) } catch { throw .invalidSenderKey }
        var key = [UInt8](repeating: 0, count: 32)
        defer { key.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        shared.withUnsafeBytes { secret in
            _ = crypto_core_hsalsa20_tweet(&key, [UInt8](repeating: 0, count: 16), secret.bindMemory(to: UInt8.self).baseAddress, sigma)
        }
        let bytes = [UInt8](data)
        let nonce = Array(bytes[..<nonceByteCount])
        let padded = [UInt8](repeating: 0, count: boxZeroByteCount) + bytes[nonceByteCount...]
        var plain = [UInt8](repeating: 0, count: padded.count)
        guard crypto_box_curve25519xsalsa20poly1305_tweet_open_afternm(&plain, padded, UInt64(padded.count), nonce, key) == 0 else {
            throw .authenticationFailed
        }
        return Data(plain[zeroByteCount...])
    }
}
