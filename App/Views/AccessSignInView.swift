import AppKit
import SwiftUI
import OhMyOpenClawCore

/// A browser sign-in to the Cloudflare Access application in front of a Gateway: the button that starts
/// it, its progress, and why it failed. It renders `state`; its caller decides what starting means.
struct AccessSignInView: View {
    let state: CloudflareAccessSignInState
    /// Whether `start` can run now.
    let canStart: Bool
    /// The accessibility identifier of the button that starts a sign-in or tries it again.
    let startButtonID: String
    let start: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    var body: some View {
        switch state {
        case .idle, .required:
            startButton("ブラウザでサインイン")
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Cloudflare Access を確認しています…")
                Spacer(minLength: 8)
                cancelButton
            }
        case .waitingForBrowser(_, let link, let opened, let host, let team):
            VStack(alignment: .leading, spacing: 8) {
                Text(AccessSignInCopy.waitingForBrowser(host: host, team: team, opened: opened))
                    .fixedSize(horizontal: false, vertical: true)
                if !opened {
                    Text(link.absoluteString)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("accessSignInLink")
                }
                HStack(spacing: 12) {
                    Button("リンクをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                    .accessibilityIdentifier("accessSignInCopyLink")
                    cancelButton
                }
                Text("このリンクを開いた人のアカウントでサインインします。ほかの人に渡さないでください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("accessSignInError")
                startButton("もう一度サインイン")
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) { start() }
            .disabled(!canStart)
            .accessibilityIdentifier(startButtonID)
    }

    private var cancelButton: some View {
        Button("キャンセル") { cancel() }
            .accessibilityIdentifier("accessSignInCancel")
    }
}

/// Over cached threads, where the connection form is hidden: the sign-in a Gateway asked for, or the
/// one under way, with the Gateway it is for. Starting it again signs in to that same Gateway.
struct AccessSignInBanner: View {
    @Bindable var model: AppModel
    let banner: AccessBanner

    private var gateway: String {
        model.savedGateways.first { $0.endpoint == banner.target.absoluteString }?.label
            ?? banner.target.host() ?? banner.target.absoluteString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AccessSignInCopy.bannerTitle(gateway: gateway), systemImage: "person.badge.key").font(.headline)
            // The error bar under the banner may already say why; once it is closed, the banner does.
            if case .required(_, let message) = banner.signIn, message != model.errorMessage {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            AccessSignInView(state: banner.signIn,
                             canStart: !model.changingConnection && model.connectionState != .connecting && !model.isSigningInToAccess,
                             startButtonID: "accessSignInBannerButton",
                             start: { Task { await model.signInWithCloudflareAccessAgain() } },
                             cancel: { model.cancelCloudflareAccessSignIn() })
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
