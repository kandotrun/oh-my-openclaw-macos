import AppKit
import Foundation
import OhMyOpenClawCore

/// Builds the app's model. UI tests set OHMYOPENCLAW_EPHEMERAL_STORE=1 so a run never
/// reads or changes the developer's saved Gateways, conversations, or Keychain items.
@MainActor
enum AppEnvironment {
    static let ephemeralStoreKey = "OHMYOPENCLAW_EPHEMERAL_STORE"
    /// With the ephemeral store only: the loopback origin where the Gateway fixture plays the
    /// Cloudflare Access relay and team domain, for a browser sign-in without Cloudflare.
    static let accessFixtureOriginKey = "OHMYOPENCLAW_ACCESS_FIXTURE_ORIGIN"

    static func makeModel(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        guard environment[ephemeralStoreKey] == "1" else {
            var access = GatewayConnectionAccess.live
            // The system browser opens only for a sign-in the person started.
            access.accessAuthenticator = .live(openBrowser: { NSWorkspace.shared.open($0) })
            return AppModel(connectionAccess: access)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyOpenClaw-Ephemeral-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "run.kandot.oh-my-openclaw.mac.ephemeral"
        UserDefaults().removePersistentDomain(forName: suite)
        let accessFixture = environment[accessFixtureOriginKey].flatMap { URL(string: $0) }.flatMap(CloudflareAccessEndpoints.loopbackFixture)
        return AppModel(
            persistenceFactory: { _ in EphemeralConversationPersistence() },
            profileRepository: LocalGatewayProfileRepository(defaults: UserDefaults(suiteName: suite) ?? .standard,
                                                             file: directory.appendingPathComponent("gateway-profiles.json")),
            connectionAccess: EphemeralConnectionAccess.make(accessFixture: accessFixture))
    }
}

/// Conversation state that lives only for this launch.
actor EphemeralConversationPersistence: ConversationPersisting {
    private var state = ConversationStore()
    func load() throws -> ConversationStore { state }
    func save(_ state: ConversationStore, revision: Int) throws { self.state = state }
}

/// Credentials and a device identity held in memory, so UI tests can reach the
/// loopback fixture without the data protection keychain.
@MainActor
enum EphemeralConnectionAccess {
    private final class Credentials { var values: [String: GatewayCredentials] = [:] }

    /// Without `accessFixture` there is no browser sign-in, as in unit tests.
    static func make(accessFixture: CloudflareAccessEndpoints?) -> GatewayConnectionAccess {
        let credentials = Credentials()
        let identity = DeviceIdentity()
        var access = GatewayConnectionAccess(
            read: { credentials.values[$0] },
            write: { credentials.values[$1] = $0 },
            delete: { credentials.values[$0] = nil },
            makeService: { url, value in GatewayClient(endpoint: url, credentials: value, identity: identity) })
        if let accessFixture { access.accessAuthenticator = .live(endpoints: accessFixture, openBrowser: openInFixtureBrowser) }
        return access
    }

    /// Plays the browser for the fixture: one GET of the sign-in link, with no cookies and no redirects,
    /// stands in for the person who approves the sign-in. A link that would leave this Mac is not opened.
    private static func openInFixtureBrowser(_ link: URL) -> Bool {
        guard AccessFixtureBrowser.mayOpen(link) else { return false }
        Task { _ = try? await CloudflareAccessSignIn.liveFetch(URLRequest(url: link), 0) }
        return true
    }
}
