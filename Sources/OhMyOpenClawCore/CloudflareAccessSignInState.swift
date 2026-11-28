import Foundation

/// Where signing a person in to a Gateway's Cloudflare Access application stands. Every state but
/// `idle` names the Gateway endpoint it is for. It lives only in memory and is never saved.
public enum CloudflareAccessSignInState: Sendable, Equatable {
    /// No sign-in is running or asked for.
    case idle
    /// The Gateway refused the connection until the person signs in, for the reason in `message`.
    case required(target: URL, message: String)
    /// Checking the Gateway's Access application before the browser opens, or, once the browser is
    /// done, saving the session and starting the connection with it.
    case checking(target: URL)
    /// The browser is at `link`, or could not be opened when `opened` is false. `host` and `team` are
    /// the Gateway host and the Access team domain that the application's signed metadata named.
    case waitingForBrowser(target: URL, link: URL, opened: Bool, host: String, team: String)
    /// The sign-in ended before a connection with its session started, for the reason in `message`.
    case failed(target: URL, message: String)

    /// The Gateway endpoint the state is for.
    public var target: URL? {
        switch self {
        case .idle: nil
        case .required(let target, _), .checking(let target), .failed(let target, _): target
        case .waitingForBrowser(let target, _, _, _, _): target
        }
    }

    /// Whether a sign-in is under way: from checking the application until the connection with its
    /// session starts.
    public var isRunning: Bool {
        switch self {
        case .checking, .waitingForBrowser: true
        case .idle, .required, .failed: false
        }
    }
}
