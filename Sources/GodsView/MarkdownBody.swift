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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = block.marker { Text(marker).foregroundStyle(Ink.dim) }
                    Text(block.text)
                        .font(block.code ? .system(size: 12, design: .monospaced)
                              : .system(size: block.heading == 0 ? 13 : max(13, 22 - CGFloat(block.heading * 2)),
                                        weight: block.heading == 0 ? .regular : .semibold))
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(block.code ? 10 : 0)
                .background(block.code ? Ink.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                .padding(.leading, block.quoted ? 12 : CGFloat(block.listDepth) * 8)
                .overlay(alignment: .leading) { if block.quoted { Rectangle().fill(Ink.faint).frame(width: 2) } }
                .padding(.top, block.heading > 0 && block.id > 0 ? 6 : 0)
            }
        }.textSelection(.enabled).task(id: source) {
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlock.parse(source, relativeTo: url) }.value
            if !Task.isCancelled { blocks = parsed }
        }
    }
}
