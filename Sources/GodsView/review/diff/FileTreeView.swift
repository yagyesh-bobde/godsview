import AppKit
import SwiftUI

struct FileTreeView: View {
    @Bindable var review: ReviewSession
    let viewed: ViewedFiles
    let openSearch: () -> Void
    let width: CGFloat
    @State private var collapsed = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text("Changed files").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                toolIcon(collapsed.isEmpty ? "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left" : "arrow.up.left.and.arrow.down.right",
                         collapsed.isEmpty ? "Collapse folders" : "Expand folders") {
                    if collapsed.isEmpty { collapsed = Set((review.snapshot?.tree ?? []).filter { $0.file == nil }.map(\.path)) }
                    else { collapsed.removeAll() }
                }
                toolIcon("magnifyingglass", "Quick open file (⌘P)", action: openSearch)
            }.padding(.leading, 14).padding(.trailing, 8).frame(height: 38)
            FieldChrome {
                TextField("Filter files…", text: $review.filter).textFieldStyle(.plain).accessibilityLabel("Filter file paths")
            }.padding(.horizontal, 10).padding(.bottom, 8)
            WorkspaceRule()
            FileTreeList(snapshot: review.snapshot, filter: review.filter, collapsed: collapsed,
                         path: review.path, reveal: review.revealRequest, follow: review.treeFollowRequest,
                         viewed: viewed.files, narrow: width < 240) { row in
                if row.file != nil { review.reveal(row.path) }
                else if !collapsed.insert(row.path).inserted { collapsed.remove(row.path) }
            }
        }
        .background(Ink.rail)
        .onChange(of: review.revealRequest) {
            guard let path = review.path else { return }
            collapsed = collapsed.filter { !path.hasPrefix($0 + "/") }
        }
    }
}

/// A fixed-height table so moving the active highlight never remeasures the file list.
private struct FileTreeList: NSViewRepresentable {
    let snapshot: ReviewSnapshot?
    let filter: String
    let collapsed: Set<String>
    let path: String?
    let reveal: Int
    let follow: Int
    let viewed: [String: Bool]
    let narrow: Bool
    let activate: (FileTreeRow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FileTreeScrollView {
        let scroll = FileTreeScrollView()
        let table = FileTreeTable()
        let column = NSTableColumn(identifier: .init("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = narrow ? 25 : 27
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Changed files")
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.click(_:))
        table.activateRow = { [weak coordinator = context.coordinator] in coordinator?.activate($0) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: FileTreeScrollView, context: Context) {
        guard let table = scroll.documentView as? FileTreeTable else { return }
        context.coordinator.update(self, table: table, scroll: scroll)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var state: FileTreeList?
        private var rows: [FileTreeRow] = []
        private var fileRows: [String: Int] = [:]
        private var lastReveal: Int?

        func update(_ next: FileTreeList, table: FileTreeTable, scroll: FileTreeScrollView) {
            let previous = state
            state = next
            let replaced = previous?.snapshot !== next.snapshot
            if previous == nil || replaced || previous?.filter != next.filter || previous?.collapsed != next.collapsed {
                rows = FileTreeRow.visible(next.snapshot?.tree ?? [], filter: next.filter, collapsed: next.collapsed)
                fileRows.removeAll(keepingCapacity: true)
                for (index, row) in rows.enumerated() where row.file != nil { fileRows[row.path] = index }
                scroll.emptyMessage.isHidden = !rows.isEmpty || next.filter.isEmpty
                table.reloadData()
            }
            if let previous, previous.narrow != next.narrow { table.rowHeight = next.narrow ? 25 : 27 }
            if previous?.viewed != next.viewed || previous?.narrow != next.narrow {
                table.enumerateAvailableRowViews { view, row in
                    if let view = view as? FileTreeCell, rows.indices.contains(row) { configure(view, row: row) }
                }
            } else if previous?.path != next.path {
                for path in [previous?.path, next.path].compactMap({ $0 }) {
                    guard let row = fileRows[path],
                          let cell = table.rowView(atRow: row, makeIfNecessary: false) as? FileTreeCell else { continue }
                    configure(cell, row: row)
                }
            }
            guard let path = next.path, let row = fileRows[path] else { return }
            let explicit = replaced || lastReveal != next.reveal
            lastReveal = next.reveal
            let completedDiffScroll = previous?.follow != next.follow && !scroll.recentlyScrolled
            let rect = table.rect(ofRow: row)
            guard !table.visibleRect.contains(rect) else { return }
            if explicit {
                // Center long jumps so the row remains visible if the PR header unfolds.
                let clip = scroll.contentView
                var destination = clip.bounds
                destination.origin.y = rect.midY - destination.height / 2
                clip.scroll(to: clip.constrainBoundsRect(destination).origin)
                scroll.reflectScrolledClipView(clip)
            } else if completedDiffScroll {
                table.scrollRowToVisible(row)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("fileTreeRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? FileTreeCell ?? FileTreeCell()
            view.identifier = id
            view.activate = { [weak self] in self?.activate(row) }
            configure(view, row: row)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

        private func configure(_ view: FileTreeCell, row index: Int) {
            guard let state else { return }
            let row = rows[index]
            view.configure(row, current: row.file != nil && row.path == state.path,
                           seen: state.viewed[row.path] == true, collapsed: state.filter.isEmpty && state.collapsed.contains(row.path),
                           narrow: state.narrow)
        }

        @objc func click(_ sender: NSTableView) { activate(sender.clickedRow) }
        func activate(_ row: Int) {
            guard rows.indices.contains(row) else { return }
            state?.activate(rows[row])
        }
    }
}

private final class FileTreeScrollView: NSScrollView {
    let emptyMessage = NSTextField(labelWithString: "No matching paths")
    private var lastWheelEvent: ContinuousClock.Instant?
    var recentlyScrolled: Bool {
        NSEvent.pressedMouseButtons != 0 || (lastWheelEvent.map { $0.duration(to: .now) < .milliseconds(180) } ?? false)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        emptyMessage.font = .systemFont(ofSize: 11)
        emptyMessage.textColor = NSColor(Ink.dim)
        emptyMessage.isHidden = true
        addSubview(emptyMessage)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = emptyMessage.intrinsicContentSize
        emptyMessage.frame = NSRect(x: 8, y: isFlipped ? 8 : bounds.height - size.height - 8,
                                    width: size.width, height: size.height)
    }

    override func scrollWheel(with event: NSEvent) {
        lastWheelEvent = .now
        super.scrollWheel(with: event)
        (documentView as? FileTreeTable)?.refreshHover()
    }
}

private final class FileTreeTable: NSTableView {
    var activateRow: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?
    private(set) var hoveredRow = -1 {
        didSet {
            if hoveredRow != oldValue {
                for row in [oldValue, hoveredRow] where row >= 0 && row < numberOfRows {
                    rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
                }
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if selectedRow >= 0, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           [36, 49, 76].contains(event.keyCode) {
            activateRow?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                      owner: self)
            addTrackingArea(area)
            hoverArea = area
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    func refreshHover() {
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredRow = visibleRect.contains(point) ? row(at: point) : -1
    }
}

private final class FileTreeCell: NSTableRowView {
    private struct Symbol: Hashable {
        let name: String
        let size: CGFloat
        let colors: [NSColor]
    }

    private static var symbols: [Symbol: NSImage] = [:]
    private static let faint = NSColor(Ink.faint)
    override var needsUpdateConstraints: Bool { get { false } set {} }
    var activate: (() -> Void)?
    private var row: FileTreeRow?
    private var current = false
    private var seen = false
    private var collapsed = false
    private var narrow = false

    func configure(_ row: FileTreeRow, current: Bool, seen: Bool, collapsed: Bool, narrow: Bool) {
        self.row = row
        self.current = current
        self.seen = seen
        self.collapsed = collapsed
        self.narrow = narrow
        toolTip = row.path
        let change = switch row.file?.status {
        case "added": "added"
        case "removed": "deleted"
        case "renamed": "renamed"
        default: "modified"
        }
        setAccessibilityLabel(row.file == nil ? "Folder " + row.name : "\(row.name), \(change)" + (seen ? ", viewed" : ""))
        setAccessibilityValue(row.file == nil ? (collapsed ? "Collapsed" : "Expanded") : (current ? "Current file" : nil))
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let table = superview as? FileTreeTable
        let hovered = table.map { $0.row(for: self) == $0.hoveredRow } ?? false
        let focused = isSelected && window?.firstResponder === table
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 5.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if current {
            NSColor(Ink.selection).setFill()
            shape.fill()
            NSColor(white: 1, alpha: 0.08).setStroke()
            shape.stroke()
        } else if hovered || focused {
            NSColor(white: 1, alpha: focused ? 0.09 : 0.04).setFill()
            shape.fill()
        }

        let leading = 9 + CGFloat(row.depth) * (narrow ? 9 : 14)
        if let file = row.file {
            let color = seen ? NSColor(Ink.green) : (current ? NSColor(Ink.dim) : Self.faint)
            drawIcon(seen ? "checkmark.circle.fill" : "doc.text", x: leading, width: 13, size: 11,
                     colors: seen ? [NSColor(Ink.detail), color] : [color])
            let textColor = NSColor(seen ? Ink.dim : (current || hovered ? Ink.text : Ink.prose))
            let font = NSFont.systemFont(ofSize: narrow ? 11.5 : 12, weight: current ? .medium : .regular)
            drawText(row.name, x: leading + 18, width: bounds.width - leading - 42, font: font, color: textColor, truncation: .byTruncatingMiddle)
            let (letter, tint) = switch file.status {
            case "added": ("A", Ink.green)
            case "removed": ("D", Ink.red)
            case "renamed": ("R", Ink.blue)
            default: ("M", Ink.blue)
            }
            drawText(letter, x: bounds.width - 20, width: 10, font: .monospacedSystemFont(ofSize: 10, weight: .bold),
                     color: NSColor(tint), truncation: .byClipping)
        } else {
            drawIcon(collapsed ? "chevron.right" : "chevron.down", x: leading, width: 9, size: 8, colors: [Self.faint])
            drawIcon("folder", x: leading + 14, width: 13, size: 11, colors: [Self.faint])
            drawText(row.name, x: leading + 32, width: bounds.width - leading - 43, font: .systemFont(ofSize: 12, weight: .medium),
                     color: NSColor(hovered ? Ink.prose : Ink.dim), truncation: .byTruncatingTail)
        }
    }

    private func drawIcon(_ name: String, x: CGFloat, width: CGFloat, size: CGFloat, colors: [NSColor]) {
        let symbol = Symbol(name: name, size: size, colors: colors)
        if Self.symbols[symbol] == nil {
            Self.symbols[symbol] = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium).applying(.init(paletteColors: colors)))
        }
        guard let icon = Self.symbols[symbol] else { return }
        icon.draw(in: NSRect(x: (x + (width - icon.size.width) / 2).rounded(), y: ((bounds.height - icon.size.height) / 2).rounded(),
                             width: icon.size.width, height: icon.size.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawText(_ text: String, x: CGFloat, width: CGFloat, font: NSFont, color: NSColor, truncation: NSLineBreakMode) {
        guard width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = ceil(font.ascender - font.descender + font.leading)
        string.draw(in: NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height))
    }
}
