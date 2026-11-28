import CryptoKit
import Foundation
import Testing
@testable import OhMyOpenClawCore

private func hex(_ string: String) -> Data {
    var bytes = [UInt8](); var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!); index = next
    }
    return Data(bytes)
}

private func privateKey(_ hexString: String) throws -> Curve25519.KeyAgreement.PrivateKey { try .init(rawRepresentation: hex(hexString)) }
private func publicKey(_ hexString: String) throws -> Curve25519.KeyAgreement.PublicKey { try .init(rawRepresentation: hex(hexString)) }

/// NaCl 20110221 tests/box2.c and box2.out; libsodium test/default/box2.c and box2.exp hold the same bytes.
private enum NaCl {
    static let bobsk = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    static let alicepk = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    static let nonce = hex("69696ee955b62b73cd62bda875fc73d68219e0036b7a0b37")
    /// box2.c c[16...]: Go's box (tag || ciphertext).
    static let box = hex("f3ffc7703f9400e52a7dfb4b3d3305d98e993b9f48681273c29650ba32fc76ce48332ea7164d96a4476fb8c531a1186ac0dfc17c98dce87b4da7f011ec48c97271d2c20f9b928fe2270d6fb863d51738b48eeee314a7cc8ab932164548e526ae90224368517acfeabd6bb3732bc0e9da99832b61ca01b6de56244a9e88d5f9b37973f622a43d14a6599b1f654cb45a74e355a5")
    static let message = hex("be075fc53c81f2d5cf141316ebeb0c7b5228c52a4c62cbd44b66849b64244ffce5ecbaaf33bd751a1ac728d45e6c61296cdc3c01233561f41db66cce314adb310e3be8250c46f06dceea3a7fa1348057e2f6556ad6b1318a024a838f21af1fde048977eb48f59ffd4924ca1c60902e52f0a089bc76897040e082f937763848645e0705")
    /// libsodium test/default/box_easy.exp line 2: the empty message, sealed with the same keys and nonce.
    static let emptyBox = hex("2539121d8e234e652d651fa4c8cff880")
}

@Suite struct NaClBoxTests {
    @Test func opensTheNaClVector() throws {
        let plain = try NaClBox.open(noncePrefixed: NaCl.nonce + NaCl.box, from: publicKey(NaCl.alicepk), using: privateKey(NaCl.bobsk))
        #expect(plain == NaCl.message)
    }

    @Test func opensTheEmptyMessage() throws {
        let plain = try NaClBox.open(noncePrefixed: NaCl.nonce + NaCl.emptyBox, from: publicKey(NaCl.alicepk), using: privateKey(NaCl.bobsk))
        #expect(plain.isEmpty)
    }

    /// golang.org/x/crypto nacl/box/box_test.go TestBox.
    @Test func opensTheGoTestBoxVector() throws {
        let box = hex("78ea30b19d2341ebbdba54180f821eec265cf86312549bea8a37652a8bb94f07b78a73ed1708085e6ddd0e943bbdeb8755079a37eb31d86163ce241164a47629c0539f330b4914cd135b3855bc2a2dfc")
        let sender = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32)).publicKey
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        #expect(try NaClBox.open(noncePrefixed: Data(repeating: 4, count: 24) + box, from: sender, using: recipient) == Data(repeating: 3, count: 64))
    }

    /// A transfer as cloudflared reads it from the relay (token/transfer.go, token/encrypt.go):
    /// x/crypto nacl/box.Seal from the box2 alice key to bob with the box2 nonce, as standard
    /// base64 of nonce || tag || ciphertext, and the sender in the padded base64url
    /// `service-public-key` header.
    @Test func opensTheGoSealedTransferBody() throws {
        let body = try #require(Data(base64Encoded: "aWlu6VW2K3PNYr2odfxz1oIZ4ANregs3qKLXF2yiSirZDY0+F85PVku8BSoEtpTJZuctjuM1G8VqNZ/iMUozXmpgRCog9zK0CREUocw+6Q48BbbniAbHKXogimHTwoA4XNJ7AiftqSvH"))
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: #require(Data(base64URL: "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo=")))
        let plain = try NaClBox.open(noncePrefixed: body, from: sender, using: privateKey(NaCl.bobsk))
        #expect(plain == Data(#"{"app_token":"app.token.fixture","org_token":"org.token.fixture"}"#.utf8))
    }

    @Test func rejectsEveryFlippedByte() throws {
        let sealed = NaCl.nonce + NaCl.box
        let sender = try publicKey(NaCl.alicepk), recipient = try privateKey(NaCl.bobsk)
        for index in sealed.indices {
            var tampered = sealed; tampered[index] ^= 0x01
            #expect(throws: NaClBoxError.authenticationFailed) { try NaClBox.open(noncePrefixed: tampered, from: sender, using: recipient) }
        }
    }

    @Test(arguments: [0, 23, 24, 39])
    func rejectsInputShorterThanNonceAndTag(count: Int) throws {
        #expect(throws: NaClBoxError.messageTooShort) {
            try NaClBox.open(noncePrefixed: (NaCl.nonce + NaCl.box).prefix(count), from: publicKey(NaCl.alicepk), using: privateKey(NaCl.bobsk))
        }
    }

    @Test func rejectsTheWrongRecipient() throws {
        #expect(throws: NaClBoxError.authenticationFailed) {
            try NaClBox.open(noncePrefixed: NaCl.nonce + NaCl.box, from: publicKey(NaCl.alicepk), using: Curve25519.KeyAgreement.PrivateKey())
        }
    }

    /// x/crypto nacl/box rejects these since 9ccaac6; CryptoKit's X25519 refuses them.
    @Test(arguments: [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ])
    func rejectsLowOrderSenderKeys(point: String) throws {
        #expect(throws: NaClBoxError.invalidSenderKey) {
            try NaClBox.open(noncePrefixed: NaCl.nonce + NaCl.box, from: publicKey(point), using: privateKey(NaCl.bobsk))
        }
    }
}
