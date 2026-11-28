import Foundation
import OhMyOpenClawCore

/// What the Cloudflare Access sign-in tells the person. While the browser is open it names the Gateway
/// host and the team domain that the application's signed metadata verified, so that a URL or setup code
/// pointing at another team's Access application does not pass unnoticed.
enum AccessSignInCopy {
    /// While the browser is at the sign-in link, or could not be opened (`opened` false) and the
    /// link is shown instead.
    static func waitingForBrowser(host: String, team: String, opened: Bool) -> String {
        "\(host) を \(team) で確認しました。"
            + (opened ? "ブラウザでサインインを完了してください。完了すると自動で接続します。" : "ブラウザを開けませんでした。次のリンクをブラウザで開いてください。")
    }

    /// The banner over cached threads, naming the Gateway the sign-in is for.
    static func bannerTitle(gateway: String) -> String {
        "\(gateway) に接続するには、Cloudflare Access にサインインしてください"
    }

    /// Who the active Gateway's session signs in, by email or else by subject, and when it expires.
    static func signedIn(as identity: CloudflareAccessClaims, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        // A fixed pattern: the POSIX locale keeps the user's 12-hour setting from changing it.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 H:mm"
        return "\(identity.email ?? identity.subject) でサインイン中（\(formatter.string(from: identity.expiresAt)) まで）"
    }
}
