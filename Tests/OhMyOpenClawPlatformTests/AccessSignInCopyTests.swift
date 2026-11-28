import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

/// Claims read from a synthetic application token: readable claims and a placeholder signature,
/// not a real credential.
private func identity(email: String?, subject: String = "person-subject", expiresAt: TimeInterval) throws -> CloudflareAccessClaims {
    var claims: [String: JSONValue] = [
        "type": .string("app"), "aud": .string("synthetic-audience"), "iss": .string("https://team.cloudflareaccess.com"),
        "sub": .string(subject), "exp": .number(expiresAt),
    ]
    if let email { claims["email"] = .string(email) }
    let segments = try [JSONValue.object(["alg": .string("RS256")]), .object(claims)].map { value in
        try JSONEncoder().encode(value).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return try #require(CloudflareAccessClaims(jwt: segments.joined(separator: ".") + ".c2lnbmF0dXJl"))
}

@Suite("Cloudflare Access sign-in copy")
struct AccessSignInCopyTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func theBrowserWaitNamesTheVerifiedHostAndTeam() {
        #expect(AccessSignInCopy.waitingForBrowser(host: "gateway.example.com", team: "team.cloudflareaccess.com", opened: true)
            == "gateway.example.com を team.cloudflareaccess.com で確認しました。ブラウザでサインインを完了してください。完了すると自動で接続します。")
    }

    @Test func aBrowserThatDidNotOpenLeavesTheLinkToThePersonAndStillNamesTheTeam() {
        #expect(AccessSignInCopy.waitingForBrowser(host: "gateway.example.com", team: "team.cloudflareaccess.com", opened: false)
            == "gateway.example.com を team.cloudflareaccess.com で確認しました。ブラウザを開けませんでした。次のリンクをブラウザで開いてください。")
    }

    @Test func theBannerNamesTheGatewayThatNeedsTheSignIn() {
        #expect(AccessSignInCopy.bannerTitle(gateway: "Work") == "Work に接続するには、Cloudflare Access にサインインしてください")
    }

    @Test func settingsShowsWhoIsSignedInUntilWhen() throws {
        // 2026-11-27 09:05 UTC is 18:05 in Tokyo.
        let signedIn = try identity(email: "person@example.com", expiresAt: 1_795_770_300)
        #expect(AccessSignInCopy.signedIn(as: signedIn, timeZone: tokyo) == "person@example.com でサインイン中（11月27日 18:05 まで）")
    }

    @Test func withoutAnEmailSettingsNamesTheSubject() throws {
        // 2027-01-02 00:07 UTC is 9:07 in Tokyo: no leading zeros but the minutes'.
        let signedIn = try identity(email: nil, subject: "person-subject", expiresAt: 1_798_848_420)
        #expect(AccessSignInCopy.signedIn(as: signedIn, timeZone: tokyo) == "person-subject でサインイン中（1月2日 9:07 まで）")
    }
}
