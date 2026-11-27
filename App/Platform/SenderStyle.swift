import Foundation
import OhMyOpenClawCore

/// How a transcript row is attributed in a shared session.
enum Attribution: Equatable, Sendable {
    /// The viewer's own row, or one that cannot be told apart from it: right-aligned, as before.
    case own
    /// Someone else's row: left-aligned with their name and avatar.
    case peer(PeerChrome)
    /// The opening task of a session that an agent created, by agent id.
    case agent(String)
    /// The agent's reply.
    case agentReply
}

struct PeerChrome: Equatable, Sendable {
    var name: String
    var initials: String
    /// Degrees, drawn as HSL(hue, 48%, 42%) like the Control UI's avatars.
    var hue: Int
}

enum SenderStyle {
    /// 32-bit FNV-1a over UTF-16 units, the Control UI's color seed.
    static func fnv1a(_ text: String) -> UInt32 {
        text.utf16.reduce(0x811C_9DC5) { hash, unit in (hash ^ UInt32(unit)) &* 0x0100_0193 }
    }

    static func hue(for sender: MessageSender) -> Int { Int(fnv1a(sender.colorSeed) % 360) }

    /// HSL(hue, 48%, 42%) as sRGB components, the Control UI's avatar fill.
    static func avatarRGB(hue: Int) -> (red: Double, green: Double, blue: Double) {
        let saturation = 0.48, lightness = 0.42
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = Double(hue % 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        return (red + base, green + base, blue + base)
    }

    /// The first letter of each of the first two words, uppercased; `?` when there are none.
    static func initials(_ name: String?) -> String {
        let letters = (name ?? "").split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// A row is mine only when its typed profile is the viewer's, as in the Control UI. One difference:
    /// a profileless viewer's own sends carry no sender, so any sender then belongs to someone else.
    static func attribution(of message: ChatMessage, viewer: ViewerIdentity) -> Attribution {
        guard message.role == .user else { return .agentReply }
        guard let sender = message.sender else { return .own }
        if let agent = sender.agentID { return .agent(agent) }
        switch viewer {
        case .unresolved:
            return .own
        case .profile(let id) where sender.profileID == id:
            return .own
        case .profile, .profileless:
            return .peer(PeerChrome(name: sender.displayName ?? "参加者", initials: initials(sender.displayName), hue: hue(for: sender)))
        }
    }
}
