import SwiftUI
import OhMyOpenClawCore

/// Connects to a Gateway with a URL and shared secret or a setup code, signs in to the Cloudflare Access
/// application in front of it through the browser, or starts the local demo.
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
    /// The sign-in row's height, which grows with the sign-in's progress. The form cannot scroll, so it
    /// makes room for the whole row; until the first measurement this is about one button.
    @State private var signInHeight: CGFloat = 20

    private var isConnecting: Bool { model.changingConnection || model.connectionState == .connecting }
    /// Both connection methods can reach a Gateway behind Cloudflare Access.
    private var accessEntry: AccessTokenEntry { AccessTokenEntry.parse(clientID: accessClientID, clientSecret: accessClientSecret) }
    private var namesGateway: Bool { !(useSetupCode ? setupCode : urlText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSubmit: Bool { !isConnecting && accessEntry != .incomplete && namesGateway }
    /// A browser sign-in sends no service token, so the token fields do not matter here.
    private var signInStart: ConnectionFormSignIn? {
        ConnectionFormSignIn.start(formNamesGateway: namesGateway, signIn: model.accessSignIn, connecting: isConnecting)
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
                    Section {
                        AccessSignInView(state: model.accessSignIn, canStart: signInStart != nil, startButtonID: "accessSignInButton",
                                         start: signIn, cancel: { model.cancelCloudflareAccessSignIn() })
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { signInHeight = $0 }
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
                            Text("本人のアカウントで操作するときは、ブラウザでサインインします。自動化にはサービストークン（Client ID と Client Secret）を使います。保存済みのサインインとトークンは、空欄のまま接続すると引き継ぎます。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                // The sign-in row and its padding come on top of the other rows.
                .frame(minHeight: (useSetupCode ? 340 : 400) + signInHeight + 20)
                // A failed sign-in is repeated only until the inputs a sign-in uses change after it.
                .onChange(of: [alias, urlText, secret, setupCode]) { model.dismissFailedCloudflareAccessSignIn() }
                .onChange(of: [usePassword, useSetupCode]) { model.dismissFailedCloudflareAccessSignIn() }

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

    /// Signs in through the browser with the inputs `submit` would send, but no service token: the
    /// session the sign-in brings back replaces a saved one. The form keeps its inputs, so that a
    /// cancelled sign-in, which saved nothing, can start again from them. Trying a failed sign-in again
    /// repeats it with what it was given, even if the form changed while it ran; an edit after the failure
    /// lets go of it. An empty form signs in to the Gateway the sign-in state is for.
    private func signIn() {
        switch signInStart {
        case .formInputs:
            let submittedURL = urlText, submittedSecret = secret, submittedAlias = alias
            let submittedCode = useSetupCode ? setupCode : "", submittedPassword = usePassword
            Task {
                await model.signInWithCloudflareAccess(urlText: submittedURL, secret: submittedSecret, password: submittedPassword,
                                                       setupCode: submittedCode, alias: submittedAlias)
            }
        case .stateTarget:
            Task { await model.signInWithCloudflareAccessAgain() }
        case nil:
            return
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
