import SwiftUI
import OhMyOpenClawCore

/// An exec or plugin approval, or an agent question, answered inline.
/// The typed answer belongs to the model, so leaving the thread keeps it.
struct PromptCard: View {
    let prompt: ApprovalPrompt
    @Binding var answer: String
    let resolve: (String) -> Void

    private var isApproval: Bool { prompt.kind == "exec" || prompt.kind == "plugin" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.title, systemImage: isApproval ? "shield.lefthalf.filled" : "questionmark.bubble")
                .font(.headline)
                .foregroundStyle(isApproval ? .orange : .indigo)
            Text(prompt.detail)
                .font(isApproval ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if prompt.choices.isEmpty {
                HStack {
                    Group {
                        if prompt.kind == "secret" { SecureField("回答を入力", text: $answer) } else { TextField("回答を入力", text: $answer) }
                    }
                    .accessibilityIdentifier("promptAnswerField")
                    Button("回答する") { resolve(answer) }
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
            } else {
                HStack(spacing: 8) {
                    if isApproval { Text("承認待ち").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    ForEach(prompt.choices, id: \.self) { choice in
                        Button(label(for: choice)) { resolve(choice) }
                            .buttonStyle(.bordered)
                            .tint(choice == "deny" ? .red : nil)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isApproval ? Color.orange : Color.indigo).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((isApproval ? Color.orange : Color.indigo).opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("promptCard")
    }

    private func label(for choice: String) -> String {
        guard isApproval else { return choice }
        switch choice {
        case "allow-once": return "今回だけ許可"
        case "allow-always": return "常に許可"
        case "deny": return "拒否"
        default: return choice
        }
    }
}
