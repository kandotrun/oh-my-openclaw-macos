import Foundation

/// How this app describes itself in `connect`. The Gateway pins paired device
/// metadata, so the Mac client never reuses the iOS platform values.
public struct GatewayClientIdentity: Sendable, Equatable {
    public var displayName: String
    public var version: String
    public var platform: String
    public var deviceFamily: String

    public init(displayName: String = "Oh My OpenClaw", version: String = "0.1.0", platform: String = "macos", deviceFamily: String = "Mac") {
        self.displayName = displayName; self.version = version; self.platform = platform; self.deviceFamily = deviceFamily
    }
}
