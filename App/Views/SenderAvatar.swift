import SwiftUI

/// Initials on the sender's hue, like the Control UI's avatars.
struct SenderAvatar: View {
    let initials: String
    let hue: Int

    var body: some View {
        Text(initials)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Self.color(hue: hue), in: Circle())
            .accessibilityHidden(true)
    }

    static func color(hue: Int) -> Color {
        let rgb = SenderStyle.avatarRGB(hue: hue)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
