import SwiftUI

/// Group native Markdown runs by block so headings, lists and code retain their layout.
struct MarkdownBlock: Identifiable {
    let id: Int
    var text: AttributedString
    var heading = 0
    var listDepth = 0
    var marker: String?
    var quoted = false
    var code = false
    var tableRow: Int?

    static func parse(_ source: String, relativeTo url: URL?) -> [Self] {
        let cleaned = source.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        guard let document = try? AttributedString(markdown: cleaned, baseURL: url) else {
            return [Self(id: 0, text: AttributedString(cleaned))]
        }
        var blocks: [Self] = []
        for (intent, range) in document.runs[\.presentationIntent] {
            var text = AttributedString(document[range])
            text.presentationIntent = nil
            for (link, span) in text.runs[\.link] where link != nil && !["https", "http", "mailto"].contains(link?.scheme?.lowercased()) {
                text[span].link = nil
            }
            var block = Self(id: blocks.count, text: text)
            var ordinal: Int?, ordered: Bool?
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): block.heading = level
                case .codeBlock: block.code = true
                case .blockQuote: block.quoted = true
                case .orderedList: block.listDepth += 1; ordered = ordered ?? true
                case .unorderedList: block.listDepth += 1; ordered = ordered ?? false
                case .listItem(let number): ordinal = ordinal ?? number
                case .tableHeaderRow: block.tableRow = component.identity; block.heading = 5
                case .tableRow: block.tableRow = component.identity
                default: break
                }
            }
            if !block.code {
                // Style inline code spans with a subtle rounded surface tint like T3 Code.
                for (inline, span) in block.text.runs[\.inlinePresentationIntent] where inline?.contains(.code) == true {
                    block.text[span].font = .system(size: 12.5, design: .monospaced)
                    block.text[span].foregroundColor = Ink.text
                    block.text[span].backgroundColor = Color.white.opacity(0.09)
                }
            }
            if let ordinal { block.marker = ordered == true ? "\(ordinal)." : "•" }
            if let row = block.tableRow, blocks.last?.tableRow == row {
                blocks[blocks.count - 1].text += AttributedString("     │     ") + text
            } else { blocks.append(block) }
        }
        return blocks
    }
}

struct MarkdownBody: View {
    let source: String
    let url: URL
    @State private var blocks: [MarkdownBlock] = []

    private func font(for block: MarkdownBlock) -> Font {
        if block.code { return .system(size: 12.5, design: .monospaced) }
        switch block.heading {
        case 0: return .system(size: 14, weight: .regular)
        case 1: return .system(size: 17, weight: .semibold)
        case 2: return .system(size: 15, weight: .semibold)
        case 3: return .system(size: 14, weight: .semibold)
        default: return .system(size: 13.5, weight: .semibold)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                let codeShape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = block.marker { Text(marker).foregroundStyle(Ink.faint) }
                    Text(block.text)
                        .font(font(for: block))
                        .foregroundStyle(block.heading == 0 ? Ink.prose : Ink.text)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(block.code ? 12 : 0)
                .background(block.code ? Ink.surface : .clear, in: codeShape)
                .overlay {
                    if block.code { codeShape.strokeBorder(Color.white.opacity(0.09)) }
                }
                .padding(.leading, block.quoted ? 12 : CGFloat(block.listDepth) * 8)
                .overlay(alignment: .leading) {
                    if block.quoted {
                        RoundedRectangle(cornerRadius: 1.5).fill(Ink.blue.opacity(0.45)).frame(width: 2.5)
                    }
                }
                .padding(.top, block.heading > 0 && block.id > 0 ? 8 : 0)
            }
        }.textSelection(.enabled).task(id: source) {
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlock.parse(source, relativeTo: url) }.value
            if !Task.isCancelled { blocks = parsed }
        }
    }
}
