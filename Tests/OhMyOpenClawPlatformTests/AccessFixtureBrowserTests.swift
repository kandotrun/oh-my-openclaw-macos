import Foundation
import Testing
@testable import OhMyOpenClawPlatform

// The UI tests' stand-in for the browser fetches the sign-in link itself, so it must never
// fetch one that leaves this Mac.

@Test(arguments: [
    "http://127.0.0.1:61234/cdn-cgi/access/cli?aud=synthetic&token=synthetic-public-key",
    "http://localhost:8080/cdn-cgi/access/cli?token=synthetic-public-key",
    "http://[::1]:8080/cdn-cgi/access/cli?token=synthetic-public-key",
])
func theFixtureBrowserOpensASignInLinkOnThisMac(_ link: String) throws {
    #expect(AccessFixtureBrowser.mayOpen(try #require(URL(string: link))))
}

@Test(arguments: [
    "https://gateway.example.com/cdn-cgi/access/cli?token=synthetic-public-key",
    "http://gateway.example.com:61234/cdn-cgi/access/cli?token=synthetic-public-key",
    "https://127.0.0.1:61234/cdn-cgi/access/cli?token=synthetic-public-key",
    "ws://127.0.0.1:61234/cdn-cgi/access/cli",
    "http://127.0.0.2:61234/cdn-cgi/access/cli",
    "http://user@127.0.0.1:61234/cdn-cgi/access/cli",
    "http://127.0.0.1.example.com/cdn-cgi/access/cli",
])
func theFixtureBrowserLeavesEveryOtherLinkUnopened(_ link: String) throws {
    #expect(!AccessFixtureBrowser.mayOpen(try #require(URL(string: link))))
}
