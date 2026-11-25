import AppKit

/// A small lexical pass for common source files. Large blobs go directly to TextKit.
enum CodeColors {
    private static let extensions: Set<String> = [
        "swift", "js", "jsx", "mjs", "ts", "tsx", "java", "kt", "go", "rs", "c", "h", "cpp", "cs",
    ]
    private static let tokens = try! NSRegularExpression(pattern:
        ##"(//[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|\b(actor|as|async|await|break|case|catch|class|const|continue|default|defer|else|enum|export|extends|false|final|fn|for|from|func|function|guard|if|impl|import|in|interface|let|match|new|nil|null|override|private|public|return|self|static|struct|switch|throw|throws|trait|true|try|type|var|while)\b"##)
    private static let comment = NSColor(white: 0.56, alpha: 1)
    private static let literal = NSColor(red: 0.66, green: 0.81, blue: 0.70, alpha: 1)
    private static let keyword = NSColor(red: 0.77, green: 0.67, blue: 0.88, alpha: 1)

    /// Markdown docs are common in reviews: tint `code` spans and lift **bold** text.
    private static let markdown = try! NSRegularExpression(pattern: #"(`[^`\n]+`)|(\*\*[^*\n]+\*\*)"#)
    private static let emphasis = NSColor(white: 0.96, alpha: 1)

    static func apply(to content: NSMutableAttributedString, path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if content.length < 512_000, ext == "md" || ext == "markdown" || ext == "mdx" {
            markdown.enumerateMatches(in: content.string, range: NSRange(location: 0, length: content.length)) { match, _, _ in
                guard let match else { return }
                content.addAttribute(.foregroundColor, value: match.range(at: 1).location != NSNotFound ? literal : emphasis,
                                     range: match.range)
            }
            return
        }
        guard content.length < 512_000, extensions.contains(ext) else { return }
        let source = content.string
        tokens.enumerateMatches(in: source, range: NSRange(location: 0, length: content.length)) { match, _, _ in
            guard let match else { return }
            let color = match.range(at: 1).location != NSNotFound ? comment :
                (match.range(at: 2).location != NSNotFound ? literal : keyword)
            content.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
