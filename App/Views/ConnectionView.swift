import SwiftUI
import OhMyOpenClawCore

/// Connects to a Gateway with a URL and shared secret or a setup code, or starts the local demo.
struct ConnectionView: View {
    @Bindable var model: AppModel
    @State private var alias = ""
    @State private var urlText = ""
    @State private var secret = ""
    @State private var usePassword = false
    @State private var setupCode = ""
    @State private var useSetupCode = false
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""

    private var isConnecting: Bool { model.changingConnection || model.connectionState == .connecting }
    private var accessEntry: AccessTokenEntry {
        useSetupCode ? .keepSaved : AccessTokenEntry.parse(clientID: accessClientID, clientSecret: accessClientSecret)
    }
    private var canSubmit: Bool {
        !isConnecting && accessEntry != .incomplete &&
            !(useSetupCode ? setupCode : urlText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Oh My OpenClaw").font(.largeTitle.weight(.semibold))
                    Text("OpenClaw Gateway に接続して、エージェントに開発を任せましょう。")
                        .foregroundStyle(.secondary)
                }

                Form {
                    TextField("表示名", text: $alias, prompt: Text("任意。空欄ならホスト名"))
                    Picker("接続方法", selection: $useSetupCode) {
                        Text("URL と認証情報").tag(false)
                        Text("セットアップコード").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useSetupCode {
                        SecureField("セットアップコード", text: $setupCode, prompt: Text("oc-pair:// から始まるコードも貼り付けられます"))
                            .accessibilityIdentifier("setupCodeField")
                    } else {
                        TextField("Gateway URL", text: $urlText, prompt: Text("wss://gateway.example.com"))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("connectionURL")
                        Picker("認証", selection: $usePassword) {
                            Text("トークン").tag(false)
                            Text("パスワード").tag(true)
                        }
                        SecureField(usePassword ? "パスワード" : "トークン", text: $secret)
                            .accessibilityIdentifier("connectionSecret")
                    }
                    if !useSetupCode {
                        Section {
                            TextField("Client ID", text: $accessClientID, prompt: Text("任意"))
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("accessClientID")
                            SecureField("Client Secret", text: $accessClientSecret, prompt: Text("任意"))
                                .accessibilityIdentifier("accessClientSecret")
                        } header: {
                            Text("Cloudflare Access")
                        } footer: {
                            if accessEntry == .incomplete {
                                Text("Client ID と Client Secret は両方入力してください。")
                                    .font(.footnote).foregroundStyle(.red)
                                    .accessibilityIdentifier("accessIncomplete")
                            } else {
                                Text("Gateway を Cloudflare Access で保護している場合は、サービストークンを入力します。保存済みのトークンは空欄のまま引き継ぎます。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(minHeight: useSetupCode ? 170 : 400)

                HStack(spacing: 12) {
                    Button(isConnecting ? "接続中…" : "Gateway に接続", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("connectButton")
                    if isConnecting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("デモを試す") { Task { await model.startDemo() } }
                        .disabled(isConnecting)
                        .accessibilityIdentifier("tryDemo")
                }

                feedback

                Text("接続情報はこの Mac のキーチェーンに保存します。リモートの Gateway には TLS で保護された wss:// URL を使ってください。デモはサンプルの会話で、Gateway や AI には接続しません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func submit() {
        let submittedURL = urlText, submittedSecret = secret, submittedAlias = alias
        let submittedCode = useSetupCode ? setupCode : "", submittedPassword = usePassword
        let entry = accessEntry
        guard entry != .incomplete else { return }
        let submittedAccess: CloudflareAccessToken? = if case .token(let token) = entry { token } else { nil }
        let submittedAccessID = accessClientID, submittedAccessSecret = accessClientSecret
        Task {
            await model.connect(urlText: submittedURL, secret: submittedSecret, password: submittedPassword, setupCode: submittedCode,
                                alias: submittedAlias, access: submittedAccess)
            if secret == submittedSecret { secret = "" }
            if setupCode == submittedCode { setupCode = "" }
            // The pair was sent together, so it leaves the form together.
            if submittedAccess != nil, accessClientID == submittedAccessID, accessClientSecret == submittedAccessSecret {
                accessClientID = ""; accessClientSecret = ""
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        switch model.connectionState {
        case .pairing(let requestID, let message):
            PairingGuidanceView(model: model, requestID: requestID, message: message)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        default:
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
