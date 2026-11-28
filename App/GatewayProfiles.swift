import Foundation
import OhMyOpenClawCore

/// Only display metadata lives here. Authentication stays in the endpoint's existing Keychain entry.
struct SavedGateway: Codable, Equatable, Identifiable, Sendable {
    let endpoint: String
    private(set) var alias: String?
    var id: String { endpoint }
    var label: String { alias ?? URL(string: endpoint)?.host ?? endpoint }
    var url: URL { get throws { try Self.exactURL(endpoint) } }

    init(url: URL, alias: String? = nil) throws {
        _ = try Self.exactURL(url.absoluteString)
        endpoint = url.absoluteString
        self.alias = Self.cleanAlias(alias)
    }

    private enum CodingKeys: String, CodingKey { case endpoint, alias }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let endpoint = try values.decode(String.self, forKey: .endpoint)
        _ = try Self.exactURL(endpoint)
        self.endpoint = endpoint
        alias = Self.cleanAlias(try values.decodeIfPresent(String.self, forKey: .alias))
    }

    mutating func rename(_ name: String) { alias = Self.cleanAlias(name) }
    private static func cleanAlias(_ name: String?) -> String? {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Validate using the existing policy, but keep the precise legacy URL for hashes and Keychain keys.
    static func exactURL(_ text: String) throws -> URL {
        _ = try GatewayEndpoint.parse(text)
        guard let url = URL(string: text), ["wss", "ws"].contains(url.scheme?.lowercased() ?? ""),
              text == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw GatewayFailure(code: "INVALID_URL", message: "保存された Gateway URL を確認してください。")
        }
        return url
    }
}

struct GatewayProfiles: Codable, Equatable, Sendable {
    private(set) var profiles: [SavedGateway] = []
    private(set) var lastActiveEndpoint: String?
    var pendingCredentialRemoval: String?
    var useDemo = false

    mutating func activate(_ url: URL, alias: String? = nil) throws {
        let incoming = try SavedGateway(url: url, alias: alias)
        if let index = profiles.firstIndex(where: { $0.endpoint == incoming.endpoint }) {
            // Blank reconnect forms must not overwrite a user's saved alias.
            if let alias = incoming.alias { profiles[index].rename(alias) }
        } else { profiles.append(incoming) }
        lastActiveEndpoint = incoming.endpoint
        useDemo = false
    }

    mutating func rename(endpoint: String, alias: String) {
        guard let index = profiles.firstIndex(where: { $0.endpoint == endpoint }) else { return }
        profiles[index].rename(alias)
    }

    mutating func remove(endpoint: String) {
        profiles.removeAll { $0.endpoint == endpoint }
        if lastActiveEndpoint == endpoint { lastActiveEndpoint = nil }
        pendingCredentialRemoval = endpoint
    }
}

@MainActor
protocol GatewayProfilePersisting {
    func load() throws -> GatewayProfiles
    func save(_ profiles: GatewayProfiles) throws
}

@MainActor
final class LocalGatewayProfileRepository: GatewayProfilePersisting {
    private let defaults: UserDefaults
    private let file: URL?
    init(defaults: UserDefaults = .standard, file: URL? = nil) {
        self.defaults = defaults; self.file = file
    }

    func load() throws -> GatewayProfiles {
        do { return try JSONDecoder().decode(GatewayProfiles.self, from: Data(contentsOf: profileFile())) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { }

        var profiles = GatewayProfiles()
        if let data = defaults.data(forKey: "savedGateways") {
            profiles = try JSONDecoder().decode(GatewayProfiles.self, from: data)
        } else {
            if let legacy = defaults.string(forKey: "lastGateway"), let url = try? SavedGateway.exactURL(legacy) {
                try profiles.activate(url)
            }
            profiles.useDemo = defaults.bool(forKey: "useDemo")
        }
        try save(profiles)
        return profiles
    }

    func save(_ profiles: GatewayProfiles) throws {
        // The deletion marker must survive app termination before Keychain removal can begin.
        try JSONEncoder().encode(profiles).write(to: profileFile(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func profileFile() throws -> URL {
        if let file { return file }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("gateway-profiles.json")
    }
}

/// Signs a person in to the Cloudflare Access application in front of a Gateway, through the system
/// browser. The browser opens only here, and only after a user action asked for it.
@MainActor
struct CloudflareAccessAuthenticator {
    /// Verifies the Access application in front of `gateway`, shows the browser link through `showLink`
    /// (with whether the browser opened, and the verified Gateway host and team domain), and returns
    /// the session once the person has signed in.
    var signIn: @MainActor (_ gateway: URL, _ showLink: @escaping @MainActor (_ link: URL, _ opened: Bool, _ host: String, _ team: String) -> Void)
        async throws -> CloudflareAccessSession

    /// No browser sign-in, as in tests and the UI tests' ephemeral store without the sign-in fixture.
    static var unavailable: Self {
        Self(signIn: { _, _ in
            throw GatewayFailure(code: "ACCESS_SIGN_IN_UNAVAILABLE", message: "この環境ではブラウザで Cloudflare Access にサインインできません。")
        })
    }

    /// The sign-in `cloudflared access login` performs: verify the application, open the browser at the
    /// link for a fresh transfer key, then wait up to five minutes for the relay to hand over the session.
    /// `openBrowser` returns false when the browser could not be opened, and the link is shown instead.
    static func live(endpoints: CloudflareAccessEndpoints = .cloudflare, openBrowser: @escaping @MainActor (URL) -> Bool) -> Self {
        Self(signIn: { gateway, showLink in
            let application = try await CloudflareAccessSignIn.discover(gateway, endpoints: endpoints, now: Date())
            let key = CloudflareAccessTransferKey()
            let link = try CloudflareAccessSignIn.signInURL(application, key: key)
            showLink(link, openBrowser(link), application.url.host() ?? "", application.authDomain)
            return try await CloudflareAccessSignIn.awaitSession(application, key: key, endpoints: endpoints,
                                                                 deadline: Date().addingTimeInterval(5 * 60))
        })
    }
}

/// A narrow seam lets state tests connect to synthetic actors without reading Keychain or device identity.
@MainActor
struct GatewayConnectionAccess {
    var read: (String) throws -> GatewayCredentials?
    var write: (GatewayCredentials, String) throws -> Void
    var delete: (String) throws -> Void
    var makeService: (URL, GatewayCredentials) throws -> any GatewayServing
    var accessAuthenticator: CloudflareAccessAuthenticator = .unavailable
    /// The wall clock that setup codes and Cloudflare Access sessions expire on.
    var now: () -> Date = { Date() }
    /// Waits out a duration, such as the time until a session expires. Tests resume it themselves.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static var live: Self {
        Self(read: { try CredentialStore.read(GatewayCredentials.self, key: $0) },
             write: { try CredentialStore.write($0, key: $1) },
             delete: { try CredentialStore.delete(key: $0) },
             makeService: { url, credentials in
                 let identity: DeviceIdentity
                 if let data = try CredentialStore.read(Data.self, key: "device-identity") {
                     identity = try DeviceIdentity(privateKeyData: data)
                 } else {
                     identity = DeviceIdentity()
                     try CredentialStore.write(identity.privateKeyData, key: "device-identity")
                 }
                 let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? GatewayClientIdentity().version
                 return GatewayClient(endpoint: url, credentials: credentials, identity: identity, clientIdentity: GatewayClientIdentity(version: version))
             })
    }
}
