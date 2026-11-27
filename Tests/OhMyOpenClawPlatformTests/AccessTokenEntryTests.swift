import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

@Suite("Cloudflare Access form entry")
struct AccessTokenEntryTests {
    @Test func blankFieldsKeepTheSavedToken() {
        #expect(AccessTokenEntry.parse(clientID: "", clientSecret: "") == .keepSaved)
        #expect(AccessTokenEntry.parse(clientID: "  ", clientSecret: "\n") == .keepSaved)
    }

    @Test func bothFieldsMakeAToken() {
        #expect(AccessTokenEntry.parse(clientID: " client.access ", clientSecret: "client-secret")
            == .token(CloudflareAccessToken(clientID: "client.access", clientSecret: "client-secret")!))
    }

    @Test func oneFieldAloneOrAnUnsendableValueIsIncomplete() {
        #expect(AccessTokenEntry.parse(clientID: "client.access", clientSecret: "") == .incomplete)
        #expect(AccessTokenEntry.parse(clientID: "", clientSecret: "client-secret") == .incomplete)
        #expect(AccessTokenEntry.parse(clientID: "client\u{7}.access", clientSecret: "client-secret") == .incomplete)
    }
}
