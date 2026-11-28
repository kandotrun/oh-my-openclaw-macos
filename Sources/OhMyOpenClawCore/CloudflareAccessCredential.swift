import Foundation

/// A Cloudflare Access credential that requests to a Gateway behind Access carry.
public protocol CloudflareAccessCredential: Sendable {
    func apply(to request: inout URLRequest)
}

/// What a connect does to the Access credential saved for a Gateway. A Gateway keeps one Access
/// credential, a person's session or a service token, because how Access treats a request that
/// carries both is unverified.
public enum AccessCredentialChange: Sendable, Equatable {
    /// Keep whichever credential is saved.
    case keep
    /// Use this service token in place of any session.
    case serviceToken(CloudflareAccessToken)
    /// Use this session in place of any service token.
    case session(CloudflareAccessSession)
}

extension GatewayCredentials {
    /// What requests to the Gateway carry through Cloudflare Access: the session when one is saved,
    /// otherwise the service token.
    public var accessCredential: (any CloudflareAccessCredential)? {
        if let accessSession { return accessSession }
        return access
    }

    /// These credentials with the Access credential that `change` leaves for `endpoint`.
    ///
    /// - `.keep` takes the service token and the session from `stored`.
    /// - `.serviceToken` sets the service token and clears the session.
    /// - `.session` sets the session and clears the service token, the device token and its scopes,
    ///   because a device token paired before the sign-in connects without the person. A session for
    ///   another origin than `endpoint`'s is refused: the result is `stored`, or empty credentials
    ///   when nothing is saved.
    public func applying(_ change: AccessCredentialChange, savedWith stored: GatewayCredentials?, for endpoint: URL) -> GatewayCredentials {
        var result = self
        switch change {
        case .keep:
            result.access = stored?.access
            result.accessSession = stored?.accessSession
        case .serviceToken(let token):
            result.access = token
            result.accessSession = nil
        case .session(let session):
            guard CloudflareAccessSession.origin(of: endpoint) == session.gatewayOrigin else { return stored ?? GatewayCredentials() }
            result.accessSession = session
            result.access = nil
            result.deviceToken = nil
            result.scopes = nil
        }
        return result
    }
}
