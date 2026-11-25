import AppKit
import SwiftUI

struct PatchLine: Equatable, Sendable {
    enum Kind: Sendable { case context, addition, deletion, hunk, note }
    let text: String
    let old: Int?
    let new: Int?
    let kind: Kind

    static func parse(_ patch: String) -> [Self] {
        var old = 0, new = 0
        return patch.components(separatedBy: "\n").map { line in
            var kind = Kind.context
            var before: Int?, after: Int?
            if line.hasPrefix("@@") {
                let fields = line.split(separator: " ")
                if fields.count >= 3 {
                    old = Int(fields[1].dropFirst().prefix(while: \.isNumber)) ?? 0
                    new = Int(fields[2].dropFirst().prefix(while: \.isNumber)) ?? 0
                }
                kind = .hunk
            } else if line.hasPrefix("-") {
                kind = .deletion
                before = old
                old += 1
            } else if line.hasPrefix("+") {
                kind = .addition
                after = new
                new += 1
            } else if line.hasPrefix(" ") {
                before = old
                after = new
                old += 1
                new += 1
            } else { kind = .note }
            return Self(text: line, old: before, new: after, kind: kind)
        }
    }
}

extension PatchLine {
    var fill: NSColor? {
        switch kind {
        case .addition: CodeTheme.additionFill
        case .deletion: CodeTheme.deletionFill
        case .hunk: CodeTheme.hunkFill
        default: nil
        }
    }
    private static var font: NSFont { CodeTheme.font }
    private static let gutterColor = CodeTheme.gutterText
    /// Changed rows have a colored fill, so their line numbers need more contrast (≥ 4.5:1).
    private static let changedGutterColor = CodeTheme.changedGutterText
    private static let codeColor = CodeTheme.text

    /// One right-aligned number column: the new line, or the old line for deletions.
    private var gutter: String {
        let width = CodeTheme.numberColumns
        let number = kind == .deletion ? old : (new ?? old)
        let digits = number.map(String.init) ?? ""
        let marker = kind == .addition ? "+" : (kind == .deletion ? "−" : " ")
        return String(repeating: " ", count: max(0, width - digits.utf8.count)) + digits + " " + marker + " "
    }

    /// "@@ -8,14 +8,15 @@ context" reads as "Lines 8–22 · context".
    var hunkTitle: String {
        let fields = text.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count >= 3, fields[0] == "@@" else { return text }
        let target = fields[2].dropFirst().split(separator: ",")
        guard let start = target.first.flatMap({ Int($0) }) else { return text }
        let count = target.count > 1 ? Int(target[1]) ?? 1 : 1
        var title = count <= 1 ? "Line \(start)" : "Lines \(start)–\(start + count - 1)"
        if let close = text.range(of: "@@", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            let context = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !context.isEmpty { title += "  ·  " + context }
        }
        return title
    }

    /// What VoiceOver reads for a diff row: change type, line numbers, then the code.
    var spokenLabel: String {
        let body = kind == .addition || kind == .deletion || kind == .context ? String(text.dropFirst()) : text
        switch kind {
        case .addition: return "Added, new line \(new ?? 0): " + body
        case .deletion: return "Removed, old line \(old ?? 0): " + body
        case .context: return "Line \(new ?? old ?? 0): " + body
        case .hunk: return "Hunk, " + hunkTitle
        case .note: return text
        }
    }

    func attributed(path: String) -> NSAttributedString {
        // One number column with a small +/− marker beside it (so changes do not rely on
        // color alone), then the code. Copy and comments still use the raw patch line.
        let marked = kind == .addition || kind == .deletion || kind == .context
        let body = marked ? String(text.dropFirst()) : (kind == .hunk ? hunkTitle : text)
        let gutter = kind == .hunk ? String(repeating: " ", count: CodeTheme.gutterColumns) : self.gutter
        let result = NSMutableAttributedString(string: gutter + body, attributes: [
            .font: Self.font, .foregroundColor: kind == .hunk ? CodeTheme.hunkText : Self.codeColor
        ])
        let gutterColor = kind == .addition || kind == .deletion ? Self.changedGutterColor : Self.gutterColor
        result.addAttribute(.foregroundColor, value: gutterColor, range: NSRange(location: 0, length: (gutter as NSString).length))
        if let edge {
            let at = (gutter as NSString).length - 2
            result.addAttribute(.foregroundColor, value: edge, range: NSRange(location: at, length: 1))
        }
        if kind == .hunk {
            // A restrained accent on the line range; the function context stays muted.
            let rangeEnd = (hunkTitle as NSString).range(of: "  ·  ").location
            let length = rangeEnd == NSNotFound ? (hunkTitle as NSString).length : rangeEnd
            result.addAttribute(.foregroundColor, value: CodeTheme.hunkAccent,
                                range: NSRange(location: (gutter as NSString).length, length: length))
        } else { CodeColors.apply(to: result, path: path) }
        return result
    }

    /// The edge bar color for changed rows.
    var edge: NSColor? {
        switch kind {
        case .addition: CodeTheme.additionEdge
        case .deletion: CodeTheme.deletionEdge
        default: nil
        }
    }
}

private let lineFill = NSAttributedString.Key("GodsViewLineFill")
private let lineEdge = NSAttributedString.Key("GodsViewLineEdge")

private final class PatchTextView: NSTextView {
    var commentForRows: ((ClosedRange<Int>) -> FileCommentTarget?)?
    var compose: ((FileCommentTarget) -> Void)?
    private var menuTarget: FileCommentTarget?

    override func menu(for event: NSEvent) -> NSMenu? {
        // TextKit may select the word beneath a secondary click as it constructs
        // its menu. Keep the explicit range the reviewer selected before that click.
        let selection = selectedRanges
        let menu = super.menu(for: event) ?? NSMenu()
        guard selection.count == 1 else { return menu }
        let original = selection[0].rangeValue
        if original.length > 0 && selectedRange() != original { setSelectedRange(original) }
        let range = selectedRange(), text = string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return menu }
        // Convert the native UTF-16 selection only when the user opens its menu.
        var index = 0, row = 0, first = 0
        while index < NSMaxRange(range) {
            let end = text.lineRange(for: NSRange(location: index, length: 0)).upperBound
            if index <= range.location && range.location < end { first = row }
            index = end
            row += 1
        }
        menuTarget = commentForRows?(first...(row - 1))
        if menuTarget != nil {
            menu.insertItem(.separator(), at: 0)
            let entry = menu.insertItem(withTitle: "Comment on selected lines…", action: #selector(commentSelection), keyEquivalent: "", at: 0)
            entry.target = self
        }
        return menu
    }

    @objc private func commentSelection() {
        if let menuTarget { compose?(menuTarget) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 {
            let origin = textContainerOrigin
            let box = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: box, in: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
                guard range.length > 0 else { return }
                let index = layoutManager.characterIndexForGlyph(at: range.location)
                if let fill = storage.attribute(lineFill, at: index, effectiveRange: nil) as? NSColor {
                    fill.setFill()
                    NSRect(x: dirtyRect.minX, y: fragment.minY + origin.y,
                           width: dirtyRect.width, height: fragment.height).intersection(dirtyRect).fill()
                }
                if let edge = storage.attribute(lineEdge, at: index, effectiveRange: nil) as? NSColor {
                    edge.setFill()
                    NSRect(x: 0, y: fragment.minY + origin.y, width: CodeTheme.edge, height: fragment.height)
                        .intersection(dirtyRect).fill()
                }
            }
        }
        super.draw(dirtyRect)
    }
}

/// Only immutable attributed strings cross from the formatter to AppKit.
private final class PreparedFileText: @unchecked Sendable {
    let value: NSAttributedString
    private init(_ value: NSMutableAttributedString) { self.value = NSAttributedString(attributedString: value) }

    static func make(_ text: String, path: String, mode: FileMode) -> PreparedFileText? {
        let base: [NSAttributedString.Key: Any] = [.font: CodeTheme.font, .foregroundColor: CodeTheme.text]
        let content = NSMutableAttributedString()
        if mode == .source {
            content.append(NSAttributedString(string: text, attributes: base))
            CodeColors.apply(to: content, path: path)
        } else {
            for line in PatchLine.parse(text) {
                if Task.isCancelled { return nil }
                let start = content.length
                content.append(line.attributed(path: path))
                content.append(NSAttributedString(string: "\n", attributes: base))
                if let fill = line.fill {
                    content.addAttribute(lineFill, value: fill, range: NSRange(location: start, length: content.length - start))
                }
                if let edge = line.edge {
                    content.addAttribute(lineEdge, value: edge, range: NSRange(location: start, length: content.length - start))
                }
            }
        }
        // A steady 20-point rhythm reads more calmly than TextKit's tight default leading.
        let whole = NSRange(location: 0, length: content.length)
        content.addAttribute(.paragraphStyle, value: CodeTheme.paragraph, range: whole)
        content.addAttribute(.baselineOffset, value: CodeTheme.baselineOffset, range: whole)
        return Task.isCancelled ? nil : PreparedFileText(content)
    }
}

// TextKit provides native selection, horizontal scrolling and incremental Find.
struct CodeTextView: NSViewRepresentable {
    let text: String
    let path: String
    let mode: FileMode
    let identity: String
    var commentForRows: ((ClosedRange<Int>) -> FileCommentTarget?)? = nil
    var compose: ((FileCommentTarget) -> Void)? = nil
    var findOnOpen: (() -> Void)? = nil

    final class Coordinator {
        var identity: String?
        fileprivate var formatting: Task<PreparedFileText?, Never>?
        @MainActor fileprivate static let rendered: NSCache<NSString, PreparedFileText> = {
            let cache = NSCache<NSString, PreparedFileText>()
            cache.totalCostLimit = 24 << 20
            cache.countLimit = 32
            return cache
        }()
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = CodeTheme.background
        let view = PatchTextView(frame: .zero)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isEditable = false
        view.isRichText = false
        view.isSelectable = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: CodeTheme.inset - 4, height: 10)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        view.autoresizingMask = [.width]
        scroll.documentView = view
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .findReviewText, object: nil, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated {
                guard let view, view.window?.attachedSheet == nil else { return }
                view.window?.makeFirstResponder(view)
                let sender = NSMenuItem()
                sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                view.performTextFinderAction(sender)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PatchTextView else { return }
        view.commentForRows = commentForRows
        view.compose = compose
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        let coordinator = context.coordinator
        coordinator.formatting?.cancel()
        let key = (identity + "/" + path) as NSString
        func install(_ buffer: PreparedFileText) {
            view.textStorage?.setAttributedString(buffer.value)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
            if let findOnOpen {
                DispatchQueue.main.async {
                    findOnOpen()
                    NotificationCenter.default.post(name: .findReviewText, object: nil)
                }
            }
        }
        if let cached = Coordinator.rendered.object(forKey: key) {
            install(cached)
            return
        }
        view.string = ""
        let worker = Task.detached(priority: .userInitiated) { [text, path, mode] in
            PreparedFileText.make(text, path: path, mode: mode)
        }
        coordinator.formatting = worker
        Task { @MainActor in
            guard let buffer = await worker.value, coordinator.identity == identity, !worker.isCancelled else { return }
            Coordinator.rendered.setObject(buffer, forKey: key, cost: buffer.value.length * 24 + 128)
            install(buffer)
        }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.identity = nil
        coordinator.formatting?.cancel()
    }
}

extension Notification.Name { static let findReviewText = Notification.Name("findReviewText") }
