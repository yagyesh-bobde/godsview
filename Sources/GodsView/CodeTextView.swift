import AppKit
import SwiftUI

struct PatchLine: Equatable {
    enum Kind { case context, addition, deletion, hunk, note }
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

private let lineFill = NSAttributedString.Key("GodsViewLineFill")

private final class PatchTextView: NSTextView {
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

// TextKit provides native selection, horizontal scrolling and incremental Find.
struct CodeTextView: NSViewRepresentable {
    let text: String
    let path: String
    let mode: FileMode
    let identity: String

    final class Coordinator {
        var identity: String?
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
        guard context.coordinator.identity != identity, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.identity = identity
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.86, alpha: 1)]
        let content = NSMutableAttributedString()
        if mode == .source {
            content.append(NSAttributedString(string: text, attributes: base))
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            for line in PatchLine.parse(text) {
                var style = base
                style[.paragraphStyle] = paragraph
                switch line.kind {
                case .addition: style[lineFill] = NSColor(red: 0.12, green: 0.25, blue: 0.18, alpha: 1)
                case .deletion: style[lineFill] = NSColor(red: 0.31, green: 0.15, blue: 0.17, alpha: 1)
                case .hunk:
                    style[lineFill] = NSColor(red: 0.11, green: 0.14, blue: 0.19, alpha: 1)
                    style[.foregroundColor] = NSColor(red: 0.56, green: 0.7, blue: 0.88, alpha: 1)
                default: break
                }
                let gutter = [line.old, line.new].map { n in n.map { String(format: "%5d", $0) } ?? "     " }.joined(separator: " ")
                var muted = style
                muted[.foregroundColor] = NSColor(white: 0.48, alpha: 1)
                content.append(NSAttributedString(string: gutter + "   ", attributes: muted))
                content.append(NSAttributedString(string: line.text + "\n", attributes: style))
            }
        }
        CodeColors.apply(to: content, path: path)
        view.textStorage?.setAttributedString(content)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

extension Notification.Name { static let findReviewText = Notification.Name("findReviewText") }
