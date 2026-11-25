import AppKit
import SwiftUI
import CoreText
import GitHubCore

/// Prefix sums map a table row to a file and local line without duplicating the patches.
/// Each file is a header row, its lines, and (except the last file) one empty gap row that
/// separates it from the next file. Every row keeps the same fixed height for fast scrolling.
struct DiffRows {
    let starts: [Int]
    let count: Int

    init(_ snapshot: ReviewSnapshot, collapsed: Set<String>) {
        var total = 0
        let last = snapshot.files.count - 1
        starts = snapshot.files.indices.map { index in
            let start = total
            total += 1
            // Collapsed headers stack directly; their divider separates them.
            if !collapsed.contains(snapshot.files[index].filename) {
                total += max(1, snapshot.lines[index].count)
                if index < last { total += 1 }
            }
            return start
        }
        count = total
    }

    /// The blank spacer row that ends an expanded file, before the next file's header.
    func isGap(_ row: Int) -> Bool {
        guard let file = location(row)?.file, file + 1 < starts.count else { return false }
        return row == starts[file + 1] - 1 && row != starts[file]
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
        scroll.drawsBackground = true
        scroll.backgroundColor = CodeTheme.background
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

        private var lastSliceX: CGFloat = 0
        private func followViewport() {
            guard let scroll, let review else { return }
            if scroll.documentVisibleRect.minX != lastSliceX {
                lastSliceX = scroll.documentVisibleRect.minX
                refreshHeaderSlices()
            }
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

        private var visibleSlice: (x: CGFloat, width: CGFloat) {
            guard let scroll else { return (0, 0) }
            let rect = scroll.documentVisibleRect
            return (rect.minX, rect.width)
        }

        /// File headers right-align their actions inside the viewport, so they follow its
        /// width and horizontal offset. Only the few header views on screen are touched.
        private func refreshHeaderSlices() {
            guard let table, let scroll else { return }
            let slice = visibleSlice
            let visible = table.rows(in: scroll.documentVisibleRect)
            for row in visible.location..<NSMaxRange(visible) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffHeader)?.visibleSlice = slice
            }
            // The floating group row is not always inside the visible range.
            for case let header as DiffHeader in table.subviews.flatMap(\.subviews) { header.visibleSlice = slice }
        }

        private func sizeColumn() {
            refreshHeaderSlices()
            guard let column = table?.tableColumns.first, let scroll, let snapshot else { return }
            // Wide code lines remain horizontally accessible, even when the viewport is narrow.
            let width = max(scroll.contentSize.width, CGFloat(snapshot.longestLine + 20) * CodeTheme.advance)
            if abs(column.width - width) > 0.5 { column.width = width }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows?.count ?? 0 }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows?.location(row)?.line == -1 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows?.isGap(row) != true }
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
            return lines.indices.contains(loc.line) ? lines[loc.line].text : nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard let snapshot, let loc = rows?.location(row), snapshot.lines[loc.file].indices.contains(loc.line) else { return nil }
            let id = NSUserInterfaceItemIdentifier("diffTextRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? DiffTextRow ?? DiffTextRow()
            view.identifier = id
            prepareNearbyRows(row, snapshot: snapshot)
            let line = snapshot.lines[loc.file][loc.line]
            view.display(layouts.layout(file: loc.file, line: loc.line, snapshot: snapshot), text: line.spokenLabel,
                         kind: line.kind, fill: line.fill)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let snapshot, let review, let rows, let loc = rows.location(row), !rows.isGap(row) else { return nil }
            let file = snapshot.files[loc.file]
            if loc.line < 0 {
                let id = NSUserInterfaceItemIdentifier("fileHeader")
                let header = tableView.makeView(withIdentifier: id, owner: self) as? DiffHeader ?? DiffHeader()
                header.identifier = id
                header.configure(path: file.filename, status: file.status, collapsed: collapsed.contains(file.filename),
                                 additions: file.additions, deletions: file.deletions)
                header.fold = {
                    if !review.collapsedFiles.insert(file.filename).inserted { review.collapsedFiles.remove(file.filename) }
                }
                header.openFile = { review.reveal(file.filename); review.mode = .source; review.singleFile = true }
                configureActions(header, path: file.filename)
                header.visibleSlice = visibleSlice
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
    private var kind = PatchLine.Kind.context
    func display(_ line: CTLine, text: String, kind: PatchLine.Kind, fill: NSColor?) {
        self.line = line
        self.kind = kind
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
        // A gutter band separates line numbers from code; changed rows also get a crisp
        // colored edge, so the change reads at a glance even with a soft row fill.
        let gutter = NSRect(x: 0, y: 0, width: CodeTheme.gutterWidth, height: bounds.height)
        switch kind {
        case .addition: CodeTheme.additionGutter.setFill()
        case .deletion: CodeTheme.deletionGutter.setFill()
        case .hunk: CodeTheme.hunkFill.setFill()
        case .note: CodeTheme.background.setFill()
        default: CodeTheme.gutterFill.setFill()
        }
        gutter.intersection(dirtyRect).fill()
        if kind == .addition || kind == .deletion {
            (kind == .addition ? CodeTheme.additionEdge : CodeTheme.deletionEdge).setFill()
            NSRect(x: 0, y: 0, width: CodeTheme.edge, height: bounds.height).intersection(dirtyRect).fill()
        }
        context.saveGState()
        context.textMatrix = .identity
        if isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let font = CodeTheme.font
        let baseline = ((bounds.height - (font.ascender - font.descender)) / 2 - font.descender).rounded()
        context.textPosition = CGPoint(x: CodeTheme.inset, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// The sticky header that starts each file: fold control, path, line counts and actions.
private final class DiffHeader: NSView {
    let toggle = NSButton()
    let fileButton = ChipButton(title: "View file", symbol: "doc.text.magnifyingglass", quiet: true)
    let viewedButton = ChipButton(title: "Viewed", symbol: "circle", toggles: true)
    // A different glyph from the PR-level Comment in the toolbar, since this one targets the file.
    let commentButton = ChipButton(title: "Comment", symbol: "plus.bubble", quiet: true)
    var markViewed: (() -> Void)?
    var comment: (() -> Void)?
    let stats = NSTextField(labelWithString: "")
    private let statusBadge = StatusBadge()

    var fold: (() -> Void)?
    var openFile: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        toggle.isBordered = false
        toggle.imagePosition = .imageLeading
        toggle.imageHugsTitle = true
        // Folders truncate from the left so the file name itself stays visible.
        (toggle.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingHead
        toggle.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        toggle.contentTintColor = NSColor(Ink.dim)
        toggle.target = self
        toggle.action = #selector(toggleFile)
        fileButton.target = self
        fileButton.action = #selector(showFile)
        fileButton.toolTip = "Open the full file"
        stats.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        viewedButton.target = self
        viewedButton.action = #selector(toggleViewed)
        viewedButton.toolTip = "Mark this file as viewed on GitHub"
        commentButton.target = self
        commentButton.action = #selector(commentOnFile)
        commentButton.toolTip = "Comment on this file. For a line comment, select diff rows and Control-click."
        for view in [toggle, statusBadge, stats, fileButton, viewedButton, commentButton] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Like T3's sticky diff header: the code surface itself, separated by hairlines.
        CodeTheme.background.setFill()
        bounds.fill()
        NSColor(white: 1, alpha: 0.09).setFill()
        let scale = window?.backingScaleFactor ?? 2
        NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 / scale : 0, width: bounds.width, height: 1 / scale).fill()
        NSRect(x: 0, y: isFlipped ? 0 : bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale).fill()
    }

    /// The part of the header the reader can see. The diff column can be much wider than
    /// the viewport (long code lines), so actions are kept inside the visible slice.
    var visibleSlice: (x: CGFloat, width: CGFloat) = (0, 0) { didSet { if oldValue != visibleSlice { needsLayout = true } } }

    override func layout() {
        super.layout()
        let start = visibleSlice.width > 0 ? visibleSlice.x : 0
        let width = visibleSlice.width > 0 ? min(visibleSlice.width, bounds.width - start) : bounds.width
        let mid = { (h: CGFloat) in ((self.bounds.height - h) / 2).rounded() }
        // As the pane narrows, Comment and then View file become icon chips (their titles
        // move to the tooltip and accessibility label) so the path keeps its room.
        commentButton.compact = width < 720
        fileButton.compact = width < 560
        var right = start + width - 10
        for chip in [commentButton, viewedButton, fileButton] {
            let size = chip.intrinsicContentSize
            right -= size.width
            chip.frame = NSRect(x: right, y: mid(size.height), width: size.width, height: size.height)
            right -= 6
        }
        right -= 8
        let statsWidth = ceil(stats.attributedStringValue.size().width) + 4
        let statsHeight = stats.intrinsicContentSize.height
        right -= statsWidth
        stats.frame = NSRect(x: right, y: mid(statsHeight), width: statsWidth, height: statsHeight)
        right -= 10 + 16
        statusBadge.frame = NSRect(x: right, y: mid(16), width: 16, height: 16)
        let toggleHeight = toggle.intrinsicContentSize.height
        let available = max(60, right - 8 - (start + 10))
        toggle.frame = NSRect(x: start + 10, y: mid(toggleHeight),
                              width: min(available, toggle.intrinsicContentSize.width), height: toggleHeight)
        // Keep the counts and badge beside the path rather than floating at the far right.
        let shift = right - (toggle.frame.maxX + 8)
        if shift > 0 {
            statusBadge.frame.origin.x -= shift
            stats.frame.origin.x -= shift
        }
    }

    func configure(path: String, status: String, collapsed: Bool, additions: Int, deletions: Int) {
        needsLayout = true
        let slash = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let title = NSMutableAttributedString(string: " " + path[..<slash], attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor(Ink.dim)])
        title.append(NSAttributedString(string: String(path[slash...]), attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor(Ink.text)]))
        toggle.attributedTitle = title
        toggle.setAccessibilityLabel(path)
        let symbol = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                             accessibilityDescription: collapsed ? "Expand" : "Collapse")
        toggle.image = symbol?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        toggle.toolTip = (collapsed ? "Expand " : "Collapse ") + path
        let tint: NSColor = status == "removed" ? NSColor(Ink.red) : (status == "added" ? NSColor(Ink.green) : NSColor(Ink.blue))
        statusBadge.letter = status == "added" ? "A" : (status == "removed" ? "D" : (status == "renamed" ? "R" : "M"))
        statusBadge.tint = tint
        statusBadge.toolTip = status.capitalized
        statusBadge.setAccessibilityLabel(status.capitalized)
        let counts = NSMutableAttributedString(string: "+\(additions)", attributes: [.foregroundColor: NSColor(Ink.green)])
        counts.append(NSAttributedString(string: "  −\(deletions)", attributes: [.foregroundColor: NSColor(Ink.red)]))
        counts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                            range: NSRange(location: 0, length: counts.length))
        stats.attributedStringValue = counts
    }
    @objc private func toggleFile() { fold?() }
    @objc private func toggleViewed() { markViewed?() }
    @objc private func commentOnFile() { comment?() }
    @objc private func showFile() { openFile?() }
}

/// The A / M / D / R letter for a file's change type, centered in a rounded square.
private final class StatusBadge: NSView {
    var letter = "M" { didSet { needsDisplay = true } }
    var tint = NSColor.systemBlue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let text = NSAttributedString(string: letter, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold), .foregroundColor: tint])
        let size = text.size()
        text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2)))
    }
}

/// A small rounded AppKit button that matches the SwiftUI controls. It draws itself (no extra
/// layers) because it lives in floating table rows that are redrawn while scrolling.
final class ChipButton: NSButton {
    private let symbol: String
    private let toggles: Bool
    /// Quiet chips have no fill or border at rest, so a row repeated for every file
    /// does not compete with the code. They keep the same hit area.
    private let quiet: Bool
    /// Icon only; the title moves to the tooltip and accessibility label.
    var compact = false {
        didSet { if compact != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String, toggles: Bool = false, quiet: Bool = false) {
        self.symbol = symbol
        self.toggles = toggles
        self.quiet = quiet
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(toggles ? .pushOnPushOff : .momentaryChange)
        setAccessibilityRole(toggles ? .checkBox : .button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    private var on: Bool { toggles && state == .on }

    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                       .foregroundColor: tint])
    }
    private var tint: NSColor {
        if on { return NSColor(Ink.green) }
        return hovered && isEnabled ? NSColor(Ink.text) : NSColor(Ink.dim)
    }
    private var icon: NSImage? {
        NSImage(systemSymbolName: on ? "checkmark.circle.fill" : symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    override var intrinsicContentSize: NSSize {
        // The whole 24-point row height is clickable; the drawn chip is 20 points tall.
        compact ? NSSize(width: 28, height: 24) : NSSize(width: ceil(label.size().width) + 14 + 5 + 16, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 2.5), xRadius: Radius.chip, yRadius: Radius.chip)
        let resting = quiet && !hovered && !isHighlighted
        let base: NSColor = on ? NSColor(Ink.green).withAlphaComponent(0.13)
            : NSColor.white.withAlphaComponent(isHighlighted ? 0.12 : (hovered && isEnabled ? 0.085 : (quiet ? 0 : 0.045)))
        base.setFill()
        shape.fill()
        if !resting {
            (on ? NSColor(Ink.green).withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.09)).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        var x: CGFloat = compact ? ((bounds.width - (icon?.size.width ?? 0)) / 2).rounded() : 8
        if let icon {
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                self.tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let y = ((bounds.height - icon.size.height) / 2).rounded()
            tinted.draw(in: NSRect(x: x, y: y, width: icon.size.width, height: icon.size.height),
                        from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            x += icon.size.width + 5
        }
        guard !compact else { return }
        let text = label
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        text.draw(at: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()))
        NSGraphicsContext.restoreGraphicsState()
    }
}
