import AppKit

/// A small lexical pass for common source files. Large blobs go directly to TextKit.
enum CodeColors {
    private static let extensions: Set<String> = [
        "swift", "js", "jsx", "mjs", "ts", "tsx", "java", "kt", "go", "rs", "c", "h", "cpp", "cs", "json",
    ]
    /// Languages whose comments start with #.
    private static let hashExtensions: Set<String> = ["py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml"]
    private static let hashTokens = try! NSRegularExpression(pattern:
        ##"((?<![\w$])#[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|\b(and|as|class|def|elif|else|end|false|for|from|if|import|in|is|lambda|module|nil|none|None|not|null|or|pass|require|return|self|then|true|True|False|while|yield|yes|no)\b|\b([A-Z][A-Za-z0-9_]+)\b|\b(\d+(?:\.\d+)?)\b"##)
    private static let tokens = try! NSRegularExpression(pattern:
        ##"(//[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|\b(actor|as|async|await|break|case|catch|class|const|continue|default|defer|else|enum|export|extends|false|final|fn|for|from|func|function|guard|if|impl|import|in|interface|let|match|new|nil|null|override|private|public|return|self|static|struct|switch|throw|throws|trait|true|try|type|var|while)\b|\b([A-Z][A-Za-z0-9_]+)\b|\b(\d+(?:\.\d+)?)\b"##)
    /// ≥ 4.5:1 on the context, addition and deletion row backgrounds.
    private static let comment = NSColor(white: 0.66, alpha: 1)
    private static let literal = NSColor(srgbRed: 0.65, green: 0.85, blue: 0.72, alpha: 1)
    private static let keyword = NSColor(srgbRed: 0.79, green: 0.68, blue: 0.93, alpha: 1)
    private static let typeName = NSColor(srgbRed: 0.62, green: 0.82, blue: 0.98, alpha: 1)
    private static let number = NSColor(srgbRed: 0.95, green: 0.80, blue: 0.56, alpha: 1)

    /// Markdown docs are common in reviews: tint headings, `code` spans and **bold** text.
    private static let markdown = try! NSRegularExpression(pattern: #"((?:^|(?<=\s))#{1,6}\s+[^\n]+)|(`[^`\n]+`)|(\*\*[^*\n]+\*\*)"#)
    private static let emphasis = NSColor(white: 0.97, alpha: 1)

    static func apply(to content: NSMutableAttributedString, path: String, startOffset: Int = 0) {
        guard startOffset <= content.length else { return }
        let searchRange = NSRange(location: startOffset, length: content.length - startOffset)
        let ext = (path as NSString).pathExtension.lowercased()
        if content.length < 512_000, ext == "md" || ext == "markdown" || ext == "mdx" {
            markdown.enumerateMatches(in: content.string, range: searchRange) { match, _, _ in
                guard let match else { return }
                let color: NSColor = match.range(at: 1).location != NSNotFound ? typeName
                    : (match.range(at: 2).location != NSNotFound ? literal : emphasis)
                content.addAttribute(.foregroundColor, value: color, range: match.range)
            }
            return
        }
        let hash = hashExtensions.contains(ext)
        guard content.length < 512_000, hash || extensions.contains(ext) else { return }
        let source = content.string
        (hash ? hashTokens : tokens).enumerateMatches(in: source, range: searchRange) { match, _, _ in
            guard let match else { return }
            let color: NSColor
            if match.range(at: 1).location != NSNotFound { color = comment }
            else if match.range(at: 2).location != NSNotFound { color = literal }
            else if match.range(at: 3).location != NSNotFound { color = keyword }
            else if match.range(at: 4).location != NSNotFound { color = typeName }
            else { color = number }
            content.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
