import SwiftUI
import OhMyOpenClawCore

/// How to approve this Mac on the Gateway host, and a way to reconnect afterwards.
struct PairingGuidanceView: View {
    @Bindable var model: AppModel
    let requestID: String
    let message: String

    private var isConnecting: Bool { model.changingConnection || model.connectionState == .connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Gateway でこの Mac を承認してください", systemImage: "lock.shield").font(.headline)
            Text(message).font(.callout)
            Text(PairingGuidance.commands(requestID: requestID))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("pairingCommands")
            Button("承認後に再接続") { Task { await model.retryConnection() } }
                .disabled(isConnecting || model.isSigningInToAccess)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
