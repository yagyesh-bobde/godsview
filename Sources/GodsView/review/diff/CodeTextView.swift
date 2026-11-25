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
        case .addition: NSColor(red: 0.12, green: 0.25, blue: 0.18, alpha: 1)
        case .deletion: NSColor(red: 0.31, green: 0.15, blue: 0.17, alpha: 1)
        case .hunk: NSColor(red: 0.11, green: 0.14, blue: 0.19, alpha: 1)
        default: nil
        }
    }
    private static var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    private static let gutterColor = NSColor(white: 0.48, alpha: 1)
    /// Changed rows have a colored fill, so their line numbers need more contrast (≥ 4.5:1).
    private static let changedGutterColor = NSColor(white: 0.78, alpha: 1)
    private static let codeColor = NSColor(white: 0.86, alpha: 1)

    private func column(_ number: Int?) -> String {
        guard let number else { return "     " }
        let digits = String(number)
        return String(repeating: " ", count: max(0, 5 - digits.utf8.count)) + digits
    }

    /// What VoiceOver reads for a diff row: change type, line numbers, then the code.
    var spokenLabel: String {
        let body = kind == .addition || kind == .deletion || kind == .context ? String(text.dropFirst()) : text
        switch kind {
        case .addition: return "Added, new line \(new ?? 0): " + body
        case .deletion: return "Removed, old line \(old ?? 0): " + body
        case .context: return "Line \(new ?? old ?? 0): " + body
        case .hunk: return "Hunk " + text
        case .note: return text
        }
    }

    func attributed(path: String) -> NSAttributedString {
        let gutter = column(old) + " " + column(new) + "  "
        // The +/− marker gets its own column so it never runs into the content (for
        // example a Markdown bullet). Copy and comments still use the raw patch line.
        let marked = kind == .addition || kind == .deletion || kind == .context
        let marker = marked ? String(text.prefix(1)) : ""
        let body = marked ? " " + String(text.dropFirst()) : text
        let result = NSMutableAttributedString(string: gutter + marker + body, attributes: [
            .font: Self.font, .foregroundColor: kind == .hunk ? NSColor.systemBlue : Self.codeColor
        ])
        let gutterColor = kind == .addition || kind == .deletion ? Self.changedGutterColor : Self.gutterColor
        let gutterLength = (gutter as NSString).length
        result.addAttribute(.foregroundColor, value: gutterColor, range: NSRange(location: 0, length: gutterLength))
        if marked, !marker.isEmpty {
            let markerColor = kind == .addition ? NSColor(Ink.green) : (kind == .deletion ? NSColor(Ink.red) : Self.gutterColor)
            result.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: gutterLength, length: (marker as NSString).length))
        }
        CodeColors.apply(to: result, path: path)
        return result
    }
}

private let lineFill = NSAttributedString.Key("GodsViewLineFill")

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
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(white: 0.86, alpha: 1)
        ]
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
            }
        }
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
        scroll.drawsBackground = false
        let view = PatchTextView(frame: .zero)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isEditable = false
        view.isRichText = false
        view.isSelectable = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 9, height: 8)
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
