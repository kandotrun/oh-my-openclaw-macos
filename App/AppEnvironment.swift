import Foundation
import OhMyOpenClawCore

/// Builds the app's model. UI tests set OHMYOPENCLAW_EPHEMERAL_STORE=1 so a run never
/// reads or changes the developer's saved Gateways, conversations, or Keychain items.
@MainActor
enum AppEnvironment {
    static let ephemeralStoreKey = "OHMYOPENCLAW_EPHEMERAL_STORE"

    static func makeModel(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        guard environment[ephemeralStoreKey] == "1" else { return AppModel() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyOpenClaw-Ephemeral-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "run.kandot.oh-my-openclaw.mac.ephemeral"
        UserDefaults().removePersistentDomain(forName: suite)
        return AppModel(
            persistenceFactory: { _ in EphemeralConversationPersistence() },
            profileRepository: LocalGatewayProfileRepository(defaults: UserDefaults(suiteName: suite) ?? .standard,
                                                             file: directory.appendingPathComponent("gateway-profiles.json")),
            connectionAccess: EphemeralConnectionAccess.make())
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

    static func make() -> GatewayConnectionAccess {
        let credentials = Credentials()
        let identity = DeviceIdentity()
        return GatewayConnectionAccess(
            read: { credentials.values[$0] },
            write: { credentials.values[$1] = $0 },
            delete: { credentials.values[$0] = nil },
            makeService: { url, value in GatewayClient(endpoint: url, credentials: value, identity: identity) })
    }
}
