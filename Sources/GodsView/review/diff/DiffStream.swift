import AppKit
import SwiftUI
import CoreText
import GitHubCore

/// Prefix sums map a table row to a file and local line without duplicating the patches.
struct DiffRows {
    let starts: [Int]
    let count: Int

    init(_ snapshot: ReviewSnapshot, collapsed: Set<String>) {
        var total = 0
        starts = snapshot.files.indices.map { index in
            let start = total
            total += 1
            if !collapsed.contains(snapshot.files[index].filename) { total += max(1, snapshot.lines[index].count) }
            return start
        }
        count = total
    }

    func location(_ row: Int) -> (file: Int, line: Int)? {
        guard row >= 0, row < count else { return nil }
        var low = 0, high = starts.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if starts[mid] <= row { low = mid } else { high = mid }
        }
        return (low, row - starts[low] - 1)
    }
}

struct DiffStream: NSViewRepresentable {
    let snapshot: ReviewSnapshot
    let review: ReviewSession
    let collapsed: Set<String>
    let reveal: Int
    let item: InboxItem
    let client: GitHubClient

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let table = DiffTable()
        let column = NSTableColumn(identifier: .init("patch"))
        column.resizingMask = []
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.floatsGroupRows = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.attach(table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.item = item
        context.coordinator.client = client
        context.coordinator.update(snapshot, review: review, collapsed: collapsed, reveal: reveal)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var item: InboxItem?
        var client: GitHubClient?
        private weak var table: DiffTable?
        private weak var scroll: NSScrollView?
        private var snapshot: ReviewSnapshot?
        private var review: ReviewSession?
        private var rows: DiffRows?
        private var collapsed = Set<String>()
        private var lastReveal = -1
        private var observers: [NSObjectProtocol] = []
        private let formatted = NSCache<NSNumber, CTLine>()
        private var viewportUpdate: Task<Void, Never>?

        func attach(_ table: DiffTable, scroll: NSScrollView) {
            self.table = table
            self.scroll = scroll
            formatted.totalCostLimit = 8 << 20
            formatted.countLimit = 2048
            table.copyRows = { [weak self] rows in rows.compactMap { self?.plainText($0) }.joined(separator: "\n") }
            scroll.contentView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sizeColumn() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followViewport() }
            })
        }

        func detach() {
            viewportUpdate?.cancel()
            viewportUpdate = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        func update(_ next: ReviewSnapshot, review: ReviewSession, collapsed: Set<String>, reveal: Int) {
            guard let table, let scroll else { return }
            self.review = review
            let replaced = snapshot !== next
            if replaced || self.collapsed != collapsed {
                let previousRow = table.rows(in: scroll.documentVisibleRect).location
                let previous = rows?.location(previousRow)
                let anchor = previous.flatMap { snapshot?.files[$0.file].filename }
                if replaced { formatted.removeAllObjects() }
                snapshot = next
                self.collapsed = collapsed
                rows = DiffRows(next, collapsed: collapsed)
                sizeColumn()
                table.reloadData()
                if !replaced, let anchor, let index = next.indices[anchor], let rows {
                    let line = collapsed.contains(anchor) ? -1 : (previous?.line ?? -1)
                    scrollTo(rows.starts[index] + line + 1)
                }
            }
            if replaced || lastReveal != reveal {
                viewportUpdate?.cancel()
                viewportUpdate = nil
                lastReveal = reveal
                if let path = review.path, let index = next.indices[path], let rows { scrollTo(rows.starts[index]) }
            }
        }

        private func scrollTo(_ row: Int) {
            guard let scroll, let table, row >= 0, row < table.numberOfRows else { return }
            let y = max(0, min(table.rect(ofRow: row).minY, table.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func followViewport() {
            guard let scroll, let review else { return }
            let top = scroll.documentVisibleRect.minY
            if review.automaticallyFoldHeader {
                if top > 100 && !review.headerCollapsed { review.headerCollapsed = true }
                if top <= 1 && review.headerCollapsed { review.headerCollapsed = false }
            }
            guard viewportUpdate == nil, visiblePath != review.path else { return }
            // Coalesce tree navigation while the native table keeps scrolling at display speed.
            viewportUpdate = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                guard let self else { return }
                viewportUpdate = nil
                if let path = visiblePath, path != review.path { review.path = path }
            }
        }

        private var visiblePath: String? {
            guard let scroll, let table, let snapshot else { return nil }
            let y = max(0, scroll.documentVisibleRect.minY)
            guard let here = rows?.location(table.row(at: NSPoint(x: 1, y: y))) else { return nil }
            return snapshot.files[here.file].filename
        }

        private func sizeColumn() {
            guard let column = table?.tableColumns.first, let scroll, let snapshot else { return }
            // Wide code lines remain horizontally accessible, even when the viewport is narrow.
            let width = max(scroll.contentSize.width, CGFloat(snapshot.longestLine + 18) * 8)
            if abs(column.width - width) > 0.5 { column.width = width }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows?.count ?? 0 }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows?.location(row)?.line == -1 }
        private func plainText(_ row: Int) -> String? {
            guard let snapshot, let loc = rows?.location(row) else { return nil }
            if loc.line < 0 { return snapshot.files[loc.file].filename }
            let lines = snapshot.lines[loc.file]
            return lines.isEmpty ? nil : lines[loc.line].text
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let snapshot, let review, let loc = rows?.location(row) else { return nil }
            let file = snapshot.files[loc.file]
            if loc.line < 0 {
                let id = NSUserInterfaceItemIdentifier("fileHeader")
                let header = tableView.makeView(withIdentifier: id, owner: self) as? DiffHeader ?? DiffHeader()
                header.identifier = id
                header.configure(path: file.filename, collapsed: collapsed.contains(file.filename),
                                 additions: file.additions, deletions: file.deletions)
                header.fold = {
                    if !review.collapsedFiles.insert(file.filename).inserted { review.collapsedFiles.remove(file.filename) }
                }
                header.openFile = { review.reveal(file.filename); review.mode = .source; review.singleFile = true }
                return header
            }
            let id = NSUserInterfaceItemIdentifier("codeLine")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? DiffLineCell ?? DiffLineCell()
            cell.identifier = id
            let lines = snapshot.lines[loc.file]
            guard !lines.isEmpty else {
                if let item, let client {
                    return NSHostingView(rootView: PatchRecoveryRow(file: file, item: item, review: review, client: client)
                        .padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading))
                }
                return nil
            }
            let line = lines[loc.line]
            let key = NSNumber(value: (UInt64(loc.file) << 32) | UInt64(loc.line))
            let shaped: CTLine
            if let cached = formatted.object(forKey: key) { shaped = cached }
            else {
                let value = line.attributed(path: file.filename)
                shaped = CTLineCreateWithAttributedString(value)
                formatted.setObject(shaped, forKey: key, cost: value.length * 24 + 192)
            }
            cell.display(shaped, text: line.text, fill: line.fill)
            return cell
        }
    }
}

final class DiffTable: NSTableView {
    var copyRows: ((IndexSet) -> String)?
    @objc func copy(_ sender: Any?) {
        guard let text = copyRows?(selectedRowIndexes), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class DiffLineCell: NSView {
    private var line: CTLine?
    private var fill: NSColor?

    func display(_ line: CTLine, text: String, fill: NSColor?) {
        self.line = line
        self.fill = fill
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let line else { return }
        if let fill {
            fill.setFill()
            dirtyRect.fill()
        }
        if (superview as? NSTableRowView)?.isSelected == true {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
            dirtyRect.fill()
        }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 8, y: (bounds.height - 14) / 2 + 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

}

private final class DiffHeader: NSView {
    let toggle = NSButton()
    let fileButton = NSButton(title: "File", target: nil, action: nil)
    let stats = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    var fold: (() -> Void)?
    var openFile: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Ink.surface).cgColor
        toggle.isBordered = false
        toggle.imagePosition = .imageLeading
        toggle.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        toggle.target = self
        toggle.action = #selector(toggleFile)
        fileButton.bezelStyle = .inline
        fileButton.controlSize = .small
        fileButton.target = self
        fileButton.action = #selector(showFile)
        stats.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        for view in [toggle, stats, fileButton] { stack.addArrangedSubview(view) }
        stack.spacing = 9
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func configure(path: String, collapsed: Bool, additions: Int, deletions: Int) {
        toggle.title = path
        toggle.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: collapsed ? "Expand" : "Collapse")
        toggle.toolTip = (collapsed ? "Expand " : "Collapse ") + path
        stats.stringValue = "+\(additions)  −\(deletions)"
        fileButton.toolTip = "Open full file"
    }
    @objc private func toggleFile() { fold?() }
    @objc private func showFile() { openFile?() }
}
