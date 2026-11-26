import Foundation
import Security
import Testing
@testable import OhMyOpenClawState

/// Unsigned test hosts cannot open the data protection keychain, so this pins
/// the item query that the signed app sends to it.
@Test func credentialItemsUseTheDataProtectionKeychainWithTheMacService() {
    let query = CredentialStore.itemQuery("gateway:example")
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(query[kSecAttrService as String] as? String == "run.kandot.oh-my-openclaw.mac.credentials")
    #expect(query[kSecAttrAccount as String] as? String == "gateway:example")
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
}
