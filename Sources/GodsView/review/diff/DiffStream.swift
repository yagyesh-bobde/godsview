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
    let viewed: ViewedFiles
    let viewedVersion: Int
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
        context.coordinator.viewed = viewed
        context.coordinator.update(snapshot, review: review, collapsed: collapsed, reveal: reveal)
        context.coordinator.updateHeaders(version: viewedVersion)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var item: InboxItem?
        var client: GitHubClient?
        var viewed: ViewedFiles?
        private var viewedVersion = -1
        private weak var table: DiffTable?
        private weak var scroll: NSScrollView?
        private var snapshot: ReviewSnapshot?
        private var review: ReviewSession?
        private var rows: DiffRows?
        private var collapsed = Set<String>()
        private var lastReveal = -1
        private var observers: [NSObjectProtocol] = []
        private var layouts = DiffLineLayouts()
        private var prefetch: Task<Void, Never>?
        private var preparedBlock: Int?
        private var viewportUpdate: Task<Void, Never>?

        func attach(_ table: DiffTable, scroll: NSScrollView) {
            self.table = table
            self.scroll = scroll
            table.copyRows = { [weak self] rows in rows.compactMap { self?.plainText($0) }.joined(separator: "\n") }
            table.commentTarget = { [weak self] selection in self?.commentTarget(selection) }
            table.compose = { [weak self] target in self?.review?.fileComment = target }
            scroll.contentView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sizeColumn() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followViewport() }
            })
        }

        func detach() {
            prefetch?.cancel()
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
                prefetch?.cancel()
                preparedBlock = nil
                if replaced { layouts = DiffLineLayouts() }
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
        private func prepareNearbyRows(_ row: Int, snapshot: ReviewSnapshot) {
            let block = row / 64
            guard block != preparedBlock, let rows else { return }
            let forward = block >= (preparedBlock ?? block)
            preparedBlock = block
            prefetch?.cancel()
            let start = max(0, (block - (forward ? 0 : 2)) * 64)
            let end = min(rows.count, (block + (forward ? 3 : 1)) * 64)
            prefetch = Task.detached(priority: .utility) { [layouts] in
                for next in start..<end {
                    if Task.isCancelled { return }
                    guard let loc = rows.location(next), snapshot.lines[loc.file].indices.contains(loc.line) else { continue }
                    _ = layouts.layout(file: loc.file, line: loc.line, snapshot: snapshot)
                }
            }
        }

        private func commentTarget(_ selection: IndexSet) -> FileCommentTarget? {
            guard let item, let snapshot, let first = selection.first, let last = selection.last,
                  last - first + 1 == selection.count,
                  let start = rows?.location(first), let end = rows?.location(last),
                  start.file == end.file, start.line >= 0,
                  snapshot.lines[start.file].indices.contains(end.line),
                  let range = PatchLine.commentRange(snapshot.lines[start.file][start.line...end.line]) else { return nil }
            return review?.commentTarget(path: snapshot.files[start.file].filename, range: range, item: item)
        }

        func updateHeaders(version: Int) {
            guard version != viewedVersion, let table, let scroll, let snapshot, let rows else { return }
            viewedVersion = version
            let visible = table.rows(in: scroll.documentVisibleRect)
            guard visible.length > 0, let first = rows.location(visible.location),
                  let last = rows.location(NSMaxRange(visible) - 1) else { return }
            for index in first.file...last.file {
                if let header = table.view(atColumn: 0, row: rows.starts[index], makeIfNecessary: false) as? DiffHeader {
                    configureActions(header, path: snapshot.files[index].filename)
                }
            }
        }

        private func configureActions(_ header: DiffHeader, path: String) {
            guard let item, let client, let review, let viewed else { return }
            header.viewedButton.state = viewed.files[path] == true ? .on : .off
            header.viewedButton.isEnabled = viewed.files[path] != nil && !viewed.pending.contains(path)
            header.markViewed = { viewed.toggle(path, item: item, client: client) }
            let target = review.commentTarget(path: path, range: nil, item: item)
            header.commentButton.isEnabled = target != nil
            header.comment = { review.fileComment = target }
        }

        private func plainText(_ row: Int) -> String? {
            guard let snapshot, let loc = rows?.location(row) else { return nil }
            if loc.line < 0 { return snapshot.files[loc.file].filename }
            let lines = snapshot.lines[loc.file]
            return lines.isEmpty ? nil : lines[loc.line].text
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard let snapshot, let loc = rows?.location(row), snapshot.lines[loc.file].indices.contains(loc.line) else { return nil }
            let id = NSUserInterfaceItemIdentifier("diffTextRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? DiffTextRow ?? DiffTextRow()
            view.identifier = id
            prepareNearbyRows(row, snapshot: snapshot)
            let line = snapshot.lines[loc.file][loc.line]
            view.display(layouts.layout(file: loc.file, line: loc.line, snapshot: snapshot), text: line.text, fill: line.fill)
            return view
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
                configureActions(header, path: file.filename)
                return header
            }
            if snapshot.lines[loc.file].isEmpty, let item, let client {
                return NSHostingView(rootView: PatchRecoveryRow(file: file, item: item, review: review, client: client)
                    .padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading))
            }
            return nil
        }
    }
}

final class DiffTable: NSTableView {
    var commentTarget: ((IndexSet) -> FileCommentTarget?)?
    var compose: ((FileCommentTarget) -> Void)?
    private var selectedTarget: FileCommentTarget?
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        if !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entry = menu.addItem(withTitle: "Comment on selected lines…", action: #selector(commentSelection), keyEquivalent: "")
        entry.target = self
        selectedTarget = commentTarget?(selectedRowIndexes)
        entry.isEnabled = selectedTarget != nil
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        return menu
    }

    @objc private func commentSelection() {
        if let selectedTarget { compose?(selectedTarget) }
    }
    var copyRows: ((IndexSet) -> String)?
    @objc func copy(_ sender: Any?) {
        guard let text = copyRows?(selectedRowIndexes), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Draw directly into AppKit's virtualized row. A text field or a second backing
/// layer for every code line adds layout and compositing work during fast scrolling.
private final class DiffTextRow: NSTableRowView {
    private var line: CTLine?
    private var fill: NSColor?
    func display(_ line: CTLine, text: String, fill: NSColor?) {
        self.line = line
        self.fill = fill
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if let fill {
            fill.setFill()
            dirtyRect.intersection(visibleRect).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let line else { return }
        context.saveGState()
        context.textMatrix = .identity
        if isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.textPosition = CGPoint(x: 8, y: (bounds.height - 14) / 2 + 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private final class DiffHeader: NSView {
    let toggle = NSButton()
    let fileButton = NSButton(title: "File", target: nil, action: nil)
    let viewedButton = NSButton(checkboxWithTitle: "Viewed", target: nil, action: nil)
    let commentButton = NSButton(title: "Comment on file", target: nil, action: nil)
    var markViewed: (() -> Void)?
    var comment: (() -> Void)?
    let stats = NSTextField(labelWithString: "")

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
        viewedButton.controlSize = .small
        viewedButton.target = self
        viewedButton.action = #selector(toggleViewed)
        commentButton.bezelStyle = .inline
        commentButton.controlSize = .small
        commentButton.target = self
        commentButton.action = #selector(commentOnFile)
        commentButton.toolTip = "Comment on this file. For a line comment, select diff rows and Control-click."
        for view in [toggle, stats, fileButton, viewedButton, commentButton] { addSubview(view) }

    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for view in [toggle, stats, fileButton, viewedButton, commentButton] {
            let size = view.intrinsicContentSize
            let width = view === toggle ? min(480, size.width) : size.width
            view.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(),
                                width: width, height: size.height)
            x += width + 9
        }
    }
    func configure(path: String, collapsed: Bool, additions: Int, deletions: Int) {
        needsLayout = true
        toggle.title = path
        toggle.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: collapsed ? "Expand" : "Collapse")
        toggle.toolTip = (collapsed ? "Expand " : "Collapse ") + path
        stats.stringValue = "+\(additions)  −\(deletions)"
        fileButton.toolTip = "Open full file"
    }
    @objc private func toggleFile() { fold?() }
    @objc private func toggleViewed() { markViewed?() }
    @objc private func commentOnFile() { comment?() }
    @objc private func showFile() { openFile?() }
}
