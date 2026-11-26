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
    let fontSize: CGFloat
    let item: InboxItem
    let client: GitHubClient
    /// Height of the PR header and diff controls drawn over the top of the diff. The diff
    /// scrolls underneath them, so the window never re-lays out while reading.
    var chrome: CGFloat = 0
    /// The part of `chrome` (the PR header) that scrolls away with the diff, like a page header.
    var foldable: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DiffScrollView()
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
        context.coordinator.setChrome(chrome, foldable: foldable)
        context.coordinator.update(snapshot, review: review, collapsed: collapsed, reveal: reveal, fontSize: fontSize)
        context.coordinator.updateHeaders(version: viewedVersion)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var item: InboxItem?
        var client: GitHubClient?
        var viewed: ViewedFiles?
        private var viewedVersion = -1
        private weak var table: DiffTable?
        private weak var scroll: DiffScrollView?
        private var snapshot: ReviewSnapshot?
        private var review: ReviewSession?
        private var rows: DiffRows?
        private var collapsed = Set<String>()
        private var lastReveal = -1
        private var observers: [NSObjectProtocol] = []
        private var layouts = DiffLineLayouts()
        private var fontSize: CGFloat = CodeTheme.defaultFontSize
        private var prefetch: Task<Void, Never>?
        private var preparedBlock: Int?
        private var viewportUpdate: Task<Void, Never>?
        private var treeFollow: Task<Void, Never>?
        private var lastVerticalScroll: ContinuousClock.Instant?
        private var lastTop: CGFloat?
        private var pinnedFile: Int?
        private var chrome: CGFloat = 0
        private var foldable: CGFloat = 0

        /// How far the reader has scrolled from the very top of the diff.
        private var scrolled: CGFloat {
            guard let scroll else { return 0 }
            return scroll.documentVisibleRect.minY + chrome
        }
        /// Height of the header and controls still covering the top of the diff.
        private var cover: CGFloat { chrome - min(max(scrolled, 0), foldable) }

        fileprivate func setChrome(_ chrome: CGFloat, foldable: CGFloat) {
            guard let scroll, chrome != self.chrome || foldable != self.foldable else { return }
            let distance = max(0, scrolled)
            self.chrome = chrome
            self.foldable = foldable
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: chrome, left: 0, bottom: 0, right: 0)
            // The scroller starts below the controls; the header covers its top while shown.
            scroll.scrollerInsets = NSEdgeInsets(top: -foldable, left: 0, bottom: 0, right: 0)
            scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: distance - chrome))
            scroll.reflectScrolledClipView(scroll.contentView)
            updatePinnedHeader()
        }

        fileprivate func attach(_ table: DiffTable, scroll: DiffScrollView) {
            self.table = table
            self.scroll = scroll
            table.copyRows = { [weak self] rows in rows.compactMap { self?.plainText($0) }.joined(separator: "\n") }
            table.commentTarget = { [weak self] selection in self?.commentTarget(selection) }
            table.compose = { [weak self] target in self?.review?.fileComment = target }
            table.askT3 = { [weak self] selection in self?.askQuestion(selection) }
            table.askQuestion = { [weak self] text in self?.review?.askAbout(text) }
            scroll.contentView.postsFrameChangedNotifications = true
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sizeColumn() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePinnedHeader() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .commentOnSelectedLines, object: nil, queue: .main) { [weak self, weak table] _ in
                MainActor.assumeIsolated {
                    guard let self, let table, table.window?.attachedSheet == nil,
                          let target = self.commentTarget(table.selectedRowIndexes) else { NSSound.beep(); return }
                    self.review?.fileComment = target
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followViewport() }
            })
        }

        func detach() {
            prefetch?.cancel()
            viewportUpdate?.cancel()
            viewportUpdate = nil
            treeFollow?.cancel()
            treeFollow = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        func update(_ next: ReviewSnapshot, review: ReviewSession, collapsed: Set<String>, reveal: Int, fontSize: CGFloat) {
            guard let table, let scroll else { return }
            self.review = review
            let replaced = snapshot !== next
            let resizedText = self.fontSize != fontSize
            if replaced || self.collapsed != collapsed || resizedText {
                let previousRow = table.rows(in: scroll.documentVisibleRect).location
                let previous = rows?.location(previousRow)
                let anchor = previous.flatMap { snapshot?.files[$0.file].filename }
                prefetch?.cancel()
                preparedBlock = nil
                self.fontSize = fontSize
                if replaced || resizedText { layouts = DiffLineLayouts(fontSize: fontSize) }
                snapshot = next
                self.collapsed = collapsed
                rows = DiffRows(next, collapsed: collapsed)
                pinnedFile = nil
                sizeColumn()
                table.reloadData()
                if !replaced, let anchor, let index = next.indices[anchor], let rows {
                    let line = collapsed.contains(anchor) ? -1 : (previous?.line ?? -1)
                    scrollTo(rows.starts[index] + line + 1)
                }
                updatePinnedHeader()
            }
            if replaced || lastReveal != reveal {
                viewportUpdate?.cancel()
                viewportUpdate = nil
                treeFollow?.cancel()
                treeFollow = nil
                lastReveal = reveal
                if let path = review.path, let index = next.indices[path], let rows { scrollTo(rows.starts[index]) }
                lastTop = scroll.documentVisibleRect.minY
            }
        }

        private func scrollTo(_ row: Int) {
            guard let scroll, let table, row >= 0, row < table.numberOfRows else { return }
            // The first file opens at the very top with the PR header; any other row lands just
            // below the controls, once the header has scrolled away.
            let target = row == 0 ? -chrome : table.rect(ofRow: row).minY - (chrome - foldable)
            let y = max(-chrome, min(target, table.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private var lastSliceX: CGFloat = 0
        func tableViewSelectionDidChange(_ notification: Notification) { table?.refreshSelectionEnd() }

        private func followViewport() {
            table?.refreshHover()
            guard let scroll, let review else { return }
            if scroll.documentVisibleRect.minX != lastSliceX {
                lastSliceX = scroll.documentVisibleRect.minX
                refreshHeaderSlices()
            }
            let top = scroll.documentVisibleRect.minY
            guard top != lastTop else { return }
            lastTop = top
            lastVerticalScroll = .now
            guard viewportUpdate == nil, visiblePath != review.path else { return }
            // Publish the highlighted file independently of moving the sidebar viewport.
            viewportUpdate = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                guard let self else { return }
                viewportUpdate = nil
                if let path = visiblePath, path != review.path {
                    review.path = path
                    scheduleTreeFollow()
                }
            }
        }

        private func scheduleTreeFollow() {
            guard treeFollow == nil else { return }
            treeFollow = Task { @MainActor [weak self] in
                while let last = self?.lastVerticalScroll {
                    let deadline = last.advanced(by: .milliseconds(140))
                    if ContinuousClock.now >= deadline { break }
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                treeFollow = nil
                review?.treeFollowRequest += 1
            }
        }

        private var visiblePath: String? {
            guard let scroll, let table, let snapshot else { return nil }
            let y = max(0, scroll.documentVisibleRect.minY + cover)
            guard let here = rows?.location(table.row(at: NSPoint(x: 1, y: y))) else { return nil }
            return snapshot.files[here.file].filename
        }

        private var visibleSlice: (x: CGFloat, width: CGFloat) {
            guard let scroll else { return (0, 0) }
            let rect = scroll.documentVisibleRect
            return (rect.minX, rect.width)
        }

        /// Keep a single header above the native table. AppKit's floating group rows
        /// detach and reattach controls as the diff crosses each file boundary.
        private func updatePinnedHeader() {
            guard let table, let scroll, let rows else { return }
            let rect = scroll.documentVisibleRect
            // The PR header scrolls away with the diff; publishing how far is render-only.
            let header = min(max(rect.minY + chrome, 0), foldable)
            if abs((review?.headerScroll ?? 0) - header) >= 0.5 || (header == 0) != ((review?.headerScroll ?? 0) == 0) {
                review?.headerScroll = header
            }
            let cover = chrome - header
            scroll.pinnedTop = cover
            let top = rect.minY + cover
            guard let location = rows.location(table.row(at: NSPoint(x: max(1, rect.minX + 1), y: max(0, top)))),
                  top > table.rect(ofRow: rows.starts[location.file]).minY else {
                scroll.setPinnedHeader(offset: nil)
                return
            }
            if location.file != pinnedFile {
                pinnedFile = location.file
                configureHeader(scroll.pinnedHeader, file: location.file)
            }
            let next = location.file + 1
            let offset = rows.starts.indices.contains(next)
                ? min(0, table.rect(ofRow: rows.starts[next]).minY - top - table.rowHeight) : 0
            scroll.setPinnedHeader(offset: offset)
        }

        /// File headers right-align their actions inside the viewport, so they follow its
        /// width and horizontal offset. Only the few header views on screen are touched.
        private func refreshHeaderSlices() {
            guard let table, let scroll, let rows else { return }
            let continues = scroll.documentVisibleRect.maxX < table.bounds.width - 4
            if review?.diffContinuesRight != continues { review?.diffContinuesRight = continues }
            let slice = visibleSlice
            let visible = table.rows(in: scroll.documentVisibleRect)
            guard visible.length > 0, let first = rows.location(visible.location),
                  let last = rows.location(NSMaxRange(visible) - 1) else { return }
            for file in first.file...last.file {
                (table.view(atColumn: 0, row: rows.starts[file], makeIfNecessary: false) as? DiffHeader)?.visibleSlice = slice
            }
        }

        private func sizeColumn() {
            guard let column = table?.tableColumns.first, let scroll, let snapshot else { return }
            // Wide code lines remain horizontally accessible, even when the viewport is narrow.
            let width = max(scroll.contentSize.width, CGFloat(snapshot.longestLine + snapshot.lineDigits + 16) * CodeTheme.advance(for: fontSize))
            if abs(column.width - width) > 0.5 { column.width = width }
            refreshHeaderSlices()
            updatePinnedHeader()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows?.count ?? 0 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard let rows, let location = rows.location(row) else { return false }
            return location.line >= 0 && !rows.isGap(row)
        }
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

        /// The selected lines of one file, quoted for an Ask T3 question.
        private func askQuestion(_ selection: IndexSet) -> String? {
            guard UserDefaults.standard.bool(forKey: "t3MCPEnabled"), T3MCP.executable != nil,
                  let snapshot, let rows, let first = selection.first,
                  let start = rows.location(first) else { return nil }
            let lines = snapshot.lines[start.file]
            var picked: [PatchLine] = []
            for row in selection {
                guard let spot = rows.location(row), spot.file == start.file, lines.indices.contains(spot.line) else { continue }
                let line = lines[spot.line]
                if line.kind == .addition || line.kind == .deletion || line.kind == .context { picked.append(line) }
            }
            guard !picked.isEmpty else { return nil }
            let path = snapshot.files[start.file].filename
            var place = "selected lines"
            if let range = PatchLine.commentRange(picked[...]) {
                let side = range.side == .left ? "old" : "new"
                let low = range.lines.lowerBound, high = range.lines.upperBound
                place = low == high ? "\(side) line \(low)" : "\(side) lines \(low)–\(high)"
            }
            var code: [String] = []
            for line in picked {
                let mark: String = line.kind == .addition ? "+" : (line.kind == .deletion ? "-" : " ")
                code.append(mark + line.text)
            }
            return "About \(path), \(place):\n\n```diff\n" + code.joined(separator: "\n") + "\n```\n\n"
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
            if let pinnedFile { configureActions(scroll.pinnedHeader, path: snapshot.files[pinnedFile].filename) }
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

        private func configureHeader(_ header: DiffHeader, file index: Int) {
            guard let snapshot, let review else { return }
            let file = snapshot.files[index]
            header.configure(path: file.filename, status: file.status, collapsed: collapsed.contains(file.filename),
                             additions: file.additions, deletions: file.deletions)
            header.fold = {
                if !review.collapsedFiles.insert(file.filename).inserted { review.collapsedFiles.remove(file.filename) }
            }
            header.openFile = { review.reveal(file.filename); review.mode = .source; review.singleFile = true }
            configureActions(header, path: file.filename)
        }

        private func plainText(_ row: Int) -> String? {
            guard let snapshot, let loc = rows?.location(row) else { return nil }
            if loc.line < 0 { return snapshot.files[loc.file].filename }
            let lines = snapshot.lines[loc.file]
            return lines.indices.contains(loc.line) ? lines[loc.line].text : nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard let snapshot, let rows, let loc = rows.location(row) else { return nil }
            if rows.isGap(row) {
                let id = NSUserInterfaceItemIdentifier("diffGapRow")
                let view = tableView.makeView(withIdentifier: id, owner: self) as? DiffGapRow ?? DiffGapRow()
                view.identifier = id
                return view
            }
            guard snapshot.lines[loc.file].indices.contains(loc.line) else {
                let id = NSUserInterfaceItemIdentifier("diffHeaderRow")
                let view = tableView.makeView(withIdentifier: id, owner: self) as? DiffHeaderRow ?? DiffHeaderRow()
                view.identifier = id
                return view
            }
            let id = NSUserInterfaceItemIdentifier("diffTextRow")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? DiffTextRow ?? DiffTextRow()
            view.identifier = id
            prepareNearbyRows(row, snapshot: snapshot)
            let line = snapshot.lines[loc.file][loc.line]
            view.display(layouts.layout(file: loc.file, line: loc.line, snapshot: snapshot), text: line.spokenLabel,
                         kind: line.kind, fill: line.fill, digits: snapshot.lineDigits, fontSize: fontSize)
            view.toolTip = line.coordinates
            // A gutter comment button appears on hover (and on a selected line) for lines that
            // can take a review comment; it comments on the selection when this row is in it.
            let commentable = line.kind == .addition || line.kind == .deletion || line.kind == .context
            view.setAccessibilityCustomActions(commentable ? [NSAccessibilityCustomAction(name: "Comment on line") { [weak view] in
                view?.comment?()
                return true
            }] : [])
            view.comment = commentable ? { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                let selection = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes : IndexSet(integer: row)
                if !tableView.selectedRowIndexes.contains(row) { tableView.selectRowIndexes(selection, byExtendingSelection: false) }
                if let target = self.commentTarget(selection) { self.review?.fileComment = target }
            } : nil
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let snapshot, let review, let rows, let loc = rows.location(row), !rows.isGap(row) else { return nil }
            let file = snapshot.files[loc.file]
            if loc.line < 0 {
                let id = NSUserInterfaceItemIdentifier("fileHeader")
                let header = tableView.makeView(withIdentifier: id, owner: self) as? DiffHeader ?? DiffHeader()
                header.identifier = id
                configureHeader(header, file: loc.file)
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

private final class DiffScrollView: NSScrollView {
    let pinnedHeader = DiffHeader()
    private let headerClip = HeaderClip()
    private var offset: CGFloat?
    /// Where the visible diff starts below the header and controls drawn over it.
    var pinnedTop: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        headerClip.clipsToBounds = true
        headerClip.isHidden = true
        headerClip.addSubview(pinnedHeader)
        addSubview(headerClip, positioned: .above, relativeTo: contentView)
    }

    required init?(coder: NSCoder) { nil }

    func setPinnedHeader(offset: CGFloat?) {
        if self.offset != offset {
            self.offset = offset
            headerClip.isHidden = offset == nil
        }
        positionHeader()
    }

    override func layout() {
        super.layout()
        positionHeader()
    }

    private func positionHeader() {
        guard let offset, let table = documentView as? NSTableView else { return }
        let clip = contentView.frame
        let height = table.rowHeight
        let frame = NSRect(x: clip.minX, y: isFlipped ? clip.minY + pinnedTop : clip.maxY - pinnedTop - height,
                           width: clip.width, height: height)
        if headerClip.frame != frame { headerClip.frame = frame }
        let headerFrame = NSRect(x: 0, y: offset, width: clip.width, height: height)
        if pinnedHeader.frame != headerFrame { pinnedHeader.frame = headerFrame }
    }
}

private final class HeaderClip: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class DiffTable: NSTableView {
    /// The one row whose gutter shows the comment button under the mouse.
    private(set) var hoveredRow = -1 { didSet { if hoveredRow != oldValue { redrawBubble(oldValue); redrawBubble(hoveredRow) } } }
    /// The last row of a selection keeps its button, so the selection can be commented on.
    private(set) var selectionEnd = -1 { didSet { if selectionEnd != oldValue { redrawBubble(oldValue); redrawBubble(selectionEnd) } } }
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }
    /// Content moves under a still pointer while scrolling, so hover follows the pointer.
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredRow = visibleRect.contains(point) ? row(at: point) : -1
    }
    func refreshSelectionEnd() {
        let rows = selectedRowIndexes
        selectionEnd = rows.count > 1 ? (rows.last ?? -1) : -1
    }
    private func redrawBubble(_ row: Int) {
        guard row >= 0, row < numberOfRows, let view = rowView(atRow: row, makeIfNecessary: false) as? DiffTextRow else { return }
        view.setNeedsDisplay(view.bubble)
    }

    var commentTarget: ((IndexSet) -> FileCommentTarget?)?
    var compose: ((FileCommentTarget) -> Void)?
    /// Returns the question text for the selected lines when T3 is set up, nil otherwise.
    var askT3: ((IndexSet) -> String?)?
    private var selectedQuestion: String?
    private var selectedTarget: FileCommentTarget?
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        if !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entry = menu.addItem(withTitle: "Comment on selected lines…", action: #selector(commentSelection), keyEquivalent: "c")
        entry.keyEquivalentModifierMask = [.command, .option]
        entry.target = self
        selectedTarget = commentTarget?(selectedRowIndexes)
        entry.isEnabled = selectedTarget != nil
        selectedQuestion = askT3?(selectedRowIndexes)
        if selectedQuestion != nil {
            let ask = menu.addItem(withTitle: "Ask T3 about selected lines…", action: #selector(askSelection), keyEquivalent: "")
            ask.target = self
        }
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        return menu
    }

    @objc private func askSelection() {
        if let selectedQuestion { askQuestion?(selectedQuestion) }
    }
    var askQuestion: ((String) -> Void)?

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
    /// Rows are laid out by hand, never with constraints. Without this, every row the table
    /// adds while scrolling asks the whole SwiftUI window to re-measure itself.
    override var needsUpdateConstraints: Bool { get { false } set {} }
    var comment: (() -> Void)?
    /// The gutter comment button, drawn over the +/− marker column so the line number stays legible.
    var bubble: NSRect {
        NSRect(x: CodeTheme.inset + CGFloat(digits) * CodeTheme.advance(for: fontSize) + 3, y: 4, width: 16, height: 16)
    }
    private var digits = CodeTheme.numberColumns
    private var fontSize = CodeTheme.defaultFontSize

    override func mouseDown(with event: NSEvent) {
        if comment != nil, showsBubble, bubble.insetBy(dx: -3, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            comment?()
            return
        }
        super.mouseDown(with: event)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        comment = nil
    }

    /// The table owns hover and selection state, so only one row can show the button at a
    /// time; per-row tracking areas missed exits while scrolling and left buttons behind.
    private var showsBubble: Bool {
        guard let table = superview as? DiffTable else { return false }
        let row = table.row(for: self)
        return row >= 0 && (row == table.hoveredRow || row == table.selectionEnd)
    }

    private var line: CTLine?
    private var fill: NSColor?
    private var kind = PatchLine.Kind.context
    func display(_ line: CTLine, text: String, kind: PatchLine.Kind, fill: NSColor?, digits: Int,
                 fontSize: CGFloat = CodeTheme.defaultFontSize) {
        self.line = line
        self.digits = digits
        self.fontSize = fontSize
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
        let gutter = NSRect(x: 0, y: 0, width: CodeTheme.gutterWidth(digits, fontSize: fontSize), height: bounds.height)
        switch kind {
        case .addition: CodeTheme.additionGutter.setFill()
        case .deletion: CodeTheme.deletionGutter.setFill()
        case .hunk: CodeTheme.hunkFill.setFill()
        case .note: CodeTheme.background.setFill()
        default: CodeTheme.gutterFill.setFill()
        }
        gutter.intersection(dirtyRect).fill()
        // Crisp 1px boundary between the line-number column and code on non-hunk rows.
        if kind != .hunk {
            let scale = window?.backingScaleFactor ?? 2
            CodeTheme.gutterRule.setFill()
            NSRect(x: gutter.maxX - 1 / scale, y: 0, width: 1 / scale, height: bounds.height)
                .intersection(dirtyRect).fill()
        } else {
            let scale = window?.backingScaleFactor ?? 2
            NSColor(white: 1, alpha: 0.05).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).intersection(dirtyRect).fill()
        }
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
        let font = CodeTheme.font(size: fontSize)
        let baseline = ((bounds.height - (font.ascender - font.descender)) / 2 - font.descender).rounded()
        context.textPosition = CGPoint(x: CodeTheme.inset, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
        if comment != nil && showsBubble { drawCommentButton() }
    }

    private func drawCommentButton() {
        // A quiet tinted chip rather than a solid blue block, so it reads as a hint.
        let rect = bubble
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor(Ink.blue).withAlphaComponent(0.2).setFill()
        shape.fill()
        NSColor(Ink.blue).withAlphaComponent(0.5).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "Comment on line")?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold))
        guard let symbol else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { box in
            symbol.draw(in: box)
            NSColor(Ink.blue).set()
            box.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (rect.midX - symbol.size.width / 2).rounded(), y: (rect.midY - symbol.size.height / 2).rounded(),
                               width: symbol.size.width, height: symbol.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The row that holds a sticky file header.
private final class DiffHeaderRow: NSTableRowView {
    /// Rows are laid out by hand, never with constraints. Without this, every row the table
    /// adds while scrolling asks the whole SwiftUI window to re-measure itself.
    override var needsUpdateConstraints: Bool { get { false } set {} }
}

/// Quiet dark recess separating one expanded file block from the next.
private final class DiffGapRow: NSTableRowView {
    /// Rows are laid out by hand, never with constraints. Without this, every row the table
    /// adds while scrolling asks the whole SwiftUI window to re-measure itself.
    override var needsUpdateConstraints: Bool { get { false } set {} }
    override func draw(_ dirtyRect: NSRect) {
        CodeTheme.fileGapFill.setFill()
        dirtyRect.fill()
        let scale = window?.backingScaleFactor ?? 2
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).intersection(dirtyRect).fill()
    }
}

/// The sticky header that starts each file: fold control, path, line counts and actions.
private final class DiffHeader: NSView {
    /// Rows are laid out by hand, never with constraints. Without this, every row the table
    /// adds while scrolling asks the whole SwiftUI window to re-measure itself.
    override var needsUpdateConstraints: Bool { get { false } set {} }
    let toggle = NSButton()
    let fileButton = ChipButton(title: "View file", symbol: "doc.text.magnifyingglass", quiet: true,
                                accessibilityName: "View full file")
    let viewedButton = ChipButton(title: "Viewed", symbol: "circle", toggles: true)
    // A different glyph from the PR-level Comment in the toolbar, since this one targets the file.
    let commentButton = ChipButton(title: "Comment", symbol: "plus.bubble", quiet: true,
                                   accessibilityName: "Comment on file")
    var markViewed: (() -> Void)?
    var comment: (() -> Void)?
    let stats = NSTextField(labelWithString: "")
    private let statusBadge = StatusBadge()
    private let actionDivider = NSView()

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
        fileButton.toolTip = "Open full file"
        stats.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        viewedButton.target = self
        viewedButton.action = #selector(toggleViewed)
        viewedButton.toolTip = "Mark this file as viewed on GitHub"
        commentButton.target = self
        commentButton.action = #selector(commentOnFile)
        commentButton.toolTip = "Comment on this file. For a line comment, select diff rows and Control-click."
        actionDivider.wantsLayer = true
        actionDivider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        for view in [toggle, statusBadge, stats, fileButton, commentButton, actionDivider, viewedButton] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // A quiet step above the code surface so the sticky header reads apart from hunk rows.
        CodeTheme.headerFill.setFill()
        bounds.fill()
        let scale = window?.backingScaleFactor ?? 2
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: isFlipped ? 0 : bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale).fill()
        NSColor(white: 1, alpha: 0.1).setFill()
        NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 / scale : 0, width: bounds.width, height: 1 / scale).fill()
    }

    /// The part of the header the reader can see. The diff column can be much wider than
    /// the viewport (long code lines), so actions are kept inside the visible slice.
    var visibleSlice: (x: CGFloat, width: CGFloat) = (0, 0) { didSet { if oldValue != visibleSlice { needsLayout = true } } }

    override func layout() {
        super.layout()
        let start = visibleSlice.width > 0 ? visibleSlice.x : 0
        let width = visibleSlice.width > 0 ? min(visibleSlice.width, bounds.width - start) : bounds.width
        let mid = { (h: CGFloat) in ((self.bounds.height - h) / 2).rounded() }
        // Viewed stays anchored at the trailing edge so reviewers can check files down a
        // straight vertical line; lower-frequency actions sit grouped quietly beside it.
        // Labels when the pane has room (they read faster than icons); icons with labeled
        // tooltips and accessibility names when it is narrow.
        commentButton.compact = width < 720
        fileButton.compact = width < 640
        viewedButton.compact = width < 360
        var right = start + width - 10
        let viewedSize = viewedButton.intrinsicContentSize
        right -= viewedSize.width
        viewedButton.frame = NSRect(x: right, y: mid(viewedSize.height), width: viewedSize.width, height: viewedSize.height)
        right -= 7
        actionDivider.frame = NSRect(x: right, y: mid(12), width: 1, height: 12)
        right -= 6
        for chip in [commentButton, fileButton] {
            let size = chip.intrinsicContentSize
            right -= size.width
            chip.frame = NSRect(x: right, y: mid(size.height), width: size.width, height: size.height)
            right -= 2
        }
        right -= 8
        let statsWidth = ceil(stats.attributedStringValue.size().width) + 4
        let statsHeight = stats.intrinsicContentSize.height
        right -= statsWidth
        stats.frame = NSRect(x: right, y: mid(statsHeight), width: statsWidth, height: statsHeight)
        right -= 8 + 16
        statusBadge.frame = NSRect(x: right, y: mid(16), width: 16, height: 16)
        let available = max(0, right - 8 - (start + 10))
        // The collapse target spans the full row height.
        toggle.frame = NSRect(x: start + 10, y: 0,
                              width: min(available, toggle.intrinsicContentSize.width), height: bounds.height)
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
        toggle.setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
        let symbol = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                             accessibilityDescription: collapsed ? "Expand" : "Collapse")
        toggle.image = symbol?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        toggle.toolTip = (collapsed ? "Expand " : "Collapse ") + path
        let tint: NSColor = status == "removed" ? NSColor(Ink.red) : (status == "added" ? NSColor(Ink.green) : NSColor(Ink.blue))
        statusBadge.letter = status == "added" ? "A" : (status == "removed" ? "D" : (status == "renamed" ? "R" : "M"))
        statusBadge.tint = tint.usingColorSpace(.sRGB) ?? .blue
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
    var tint = NSColor.blue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        tint.withAlphaComponent(0.14).setFill()
        shape.fill()
        tint.withAlphaComponent(0.28).setStroke()
        shape.lineWidth = 0.75
        shape.stroke()
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

    init(title: String, symbol: String, toggles: Bool = false, quiet: Bool = false, accessibilityName: String? = nil) {
        self.symbol = symbol
        self.toggles = toggles
        self.quiet = quiet
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(toggles ? .pushOnPushOff : .momentaryChange)
        setAccessibilityRole(toggles ? .checkBox : .button)
        setAccessibilityLabel(accessibilityName ?? title)
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
            .withSymbolConfiguration(.init(pointSize: compact ? 10.5 : 10, weight: .semibold))
    }

    override var intrinsicContentSize: NSSize {
        // The whole 24-point row height is clickable; the drawn chip is 20 points tall.
        compact ? NSSize(width: 24, height: 24) : NSSize(width: ceil(label.size().width) + 14 + 5 + 16, height: 24)
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
