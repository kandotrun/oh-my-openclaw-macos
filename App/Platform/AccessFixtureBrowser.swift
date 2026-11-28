import Foundation

/// UI tests only: the Gateway fixture's stand-in for the browser, which fetches the Cloudflare Access
/// sign-in link itself in place of the person who approves it.
enum AccessFixtureBrowser {
    /// Plain http on 127.0.0.1, localhost or [::1], with no user info: a link that stays on this Mac.
    static func mayOpen(_ link: URL) -> Bool {
        guard let parts = URLComponents(url: link, resolvingAgainstBaseURL: false), parts.scheme == "http",
              parts.user == nil, parts.password == nil else { return false }
        return ["127.0.0.1", "localhost", "[::1]"].contains(parts.encodedHost ?? "")
    }
}
