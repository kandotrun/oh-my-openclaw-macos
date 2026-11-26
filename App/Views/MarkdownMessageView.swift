import AppKit
import SwiftUI
import OhMyOpenClawCore

/// Block layout stays native while Foundation handles inline Markdown and links.
/// Code is always literal and never evaluated or loaded into a web view.
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): inline(text)
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 2)
                case .bullet(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(.secondary)
                        inline(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.3)).frame(width: 3)
                        inline(text).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let source): CodeBlockView(language: language, source: source)
                }
            }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }

    private func inline(_ string: String) -> Text {
        let value = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return value.map(Text.init) ?? Text(string)
    }
}

private struct CodeBlockView: View {
    let language: String
    let source: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "コード" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "コピー済み" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("コードをコピー")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}
