import AppKit
import SwiftUI
import Testing
@testable import GitHubCore
@testable import GodsView

/// Scrolls a large synthetic PR in the real workspace window, down from the top and back up,
/// and reports how long each step takes on the main thread. Runs only when asked:
///
///     GODSVIEW_SCROLL_BENCH=1 swift test --filter scrollLargePullRequest
///     GODSVIEW_SCROLL_BENCH=review swift test --filter scrollLargePullRequest
@MainActor @Test func scrollLargePullRequest() async throws {
    guard let mode = ProcessInfo.processInfo.environment["GODSVIEW_SCROLL_BENCH"] else { return }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let size = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 949)
    let store = Workspace(client: GitHubClient(cli: BenchCLI(crossFiles: mode == "review")))
    await store.refresh()
    store.selection = store.items.first { $0.pr.number == 482 }?.id
    let controls = WindowControls()
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentView = TracingHost(rootView: FixtureRoot(store: store, controls: controls)
    .foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
    .ignoresSafeArea(.container, edges: .top)
    .background(WindowReader(controls: controls)))
    window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), display: false)
    window.orderFrontRegardless()
    try await settle(seconds: 2)

    guard let scroll = findDiffScroll(window.contentView) else { throw CLIError("No diff scroll view") }
    defer { window.orderOut(nil); window.close() }
    let step: CGFloat = 60  // a brisk trackpad flick moves roughly this far per frame
    var frames: [Double] = []
    func frame(_ scroll: NSScrollView, to y: CGFloat) {
        let start = CACurrentMediaTime()
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        let scrolled = CACurrentMediaTime()
        RunLoop.main.run(until: Date())
        window.displayIfNeeded()
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms > 12 { print(String(format: "SCROLLBENCH slow %.1fms at y=%.0f (scroll %.1fms)", ms, y, (scrolled - start) * 1000)) }
        frames.append(ms)
    }
    if mode == "review" {
        guard let content = window.contentView else { throw CLIError("No workspace content view") }
        let diffFrame = scroll.convert(scroll.bounds, to: content)
        guard let tree = scrollViews(in: content).first(where: { candidate in
            let rect = candidate.convert(candidate.bounds, to: content)
            return rect.minX >= diffFrame.maxX - 1 && rect.maxX <= content.bounds.maxX + 1 && rect.height > 100
        }) else {
            throw CLIError("No changed files scroll view")
        }
        // Yield between events so display updates, folder selection and header animations
        // run under the same frame budget as the scroll events.
        func gesture(_ target: NSScrollView, distance: CGFloat, step: CGFloat, label: String) async throws {
            frames.removeAll()
            let clock = ContinuousClock()
            var deadline = clock.now
            var furthest: CGFloat = 0
            for y in Array(stride(from: 0, to: distance, by: step)) + Array(stride(from: distance, through: 0, by: -step)) {
                try await clock.sleep(until: deadline)
                frame(target, to: y)
                furthest = max(furthest, target.documentVisibleRect.minY)
                deadline = max(deadline + .microseconds(8333), clock.now)
            }
            #expect(furthest >= distance - 1)
            report(frames, label: label)
        }
        try await gesture(scroll, distance: 12_000, step: 100, label: "cross-file diff")
        try await settle(seconds: 0.4)
        try await gesture(tree, distance: 2600, step: 40, label: "changed files")
        try await gesture(scroll, distance: 360, step: 24, label: "header transition")

        // Explicit navigation must still reveal a file well beyond the tree's viewport.
        let snapshot = try #require(store.review.snapshot)
        let file = try #require(snapshot.files.last)
        let treeTable = try #require(tree.documentView as? NSTableView)
        let fileRow = try #require(snapshot.tree.firstIndex { $0.file?.filename == file.filename })
        store.review.reveal(file.filename)
        try await settle(seconds: 0.3)
        #expect(treeTable.visibleRect.contains(treeTable.rect(ofRow: fileRow)))
        #expect(scroll.documentVisibleRect.minY > 12_000)

        let firstFileRow = try #require(snapshot.tree.firstIndex { $0.file != nil })
        treeTable.selectRowIndexes(IndexSet(integer: firstFileRow), byExtendingSelection: false)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        treeTable.keyDown(with: enter)
        #expect(store.review.path == snapshot.tree[firstFileRow].path)
        return
    }
    if mode == "top" {
        // Bounce across the header fold point so a sampler sees mostly that work.
        for _ in 0..<40 {
            for y in stride(from: 0, through: 240, by: 60) { frame(scroll, to: CGFloat(y)) }
            for y in stride(from: 240, through: 0, by: -60) { frame(scroll, to: CGFloat(y)) }
            for _ in 0..<20 { frame(scroll, to: 0); try await Task.sleep(for: .milliseconds(8)) }
        }
        return
    }
    // Two passes: the first touches every row cold, the second is warm.
    let passes = mode == "long" ? 12 : 2
    TraceState.tracing = ProcessInfo.processInfo.environment["GODSVIEW_TRACE"] != nil
    for pass in 1...passes {
        frames.removeAll()
        let bottom = min(6000, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        var y: CGFloat = 0
        while y < bottom { y += step; frame(scroll, to: min(y, bottom)) }
        while y > 0 { y -= step; frame(scroll, to: max(y, 0)) }
        // A short tail at the top lets any header animation finish inside the measurement.
        for _ in 0..<30 { frame(scroll, to: 0); try await Task.sleep(for: .milliseconds(8)) }
        report(frames, label: "pass \(pass)")
    }
}

private func report(_ frames: [Double], label: String) {
    let sorted = frames.sorted()
    let total = frames.reduce(0, +)
    let slow = frames.filter { $0 > 8.3 }.count
    print(String(format: "SCROLLBENCH %@: frames %d total %.1fms mean %.2fms p95 %.2fms max %.2fms over8ms %d",
                 label, frames.count, total, total / Double(frames.count),
                 sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, slow))
}

@MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
}

@MainActor func findDiffScroll(_ view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    if let scroll = view as? NSScrollView, scroll.documentView is DiffTable { return scroll }
    for child in view.subviews { if let found = findDiffScroll(child) { return found } }
    return nil
}

/// The fixture PR, but with 40 files of about 300 lines each.
private struct BenchCLI: CommandRunning {
    let crossFiles: Bool

    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        if arguments.joined(separator: " ").contains("/pulls/482/files") {
            return crossFiles ? Self.shortFiles : Self.longFiles
        }
        if arguments.joined(separator: " ").contains("query ViewedFiles") {
            return Data(#"[{"data":{"node":{"files":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]"#.utf8)
        }
        return try await FixtureCLI().run(arguments, token: token, input: input)
    }

    private static let longFiles = makeFiles(count: 40, length: 300)
    private static let shortFiles = makeFiles(count: 240, length: 24)

    private static func makeFiles(count: Int, length: Int) -> Data {
        var lines = ["@@ -1,\(length) +1,\(length) @@"]
        for index in 0..<length {
            switch index % 7 {
            case 0: lines.append("+  const value\(index) = clampGrid(config.rows, config.columns, { maxRows: 6 }); // row \(index)")
            case 1: lines.append("-  return { rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS, index: \(index) };")
            case 2: lines.append(" export function useGridSize\(index)(section: SectionPayload): GridSize {")
            case 3: lines.append("+    if (!section.layout_config) { return fallback(\"grid-\(index)\", 'cards'); }")
            default: lines.append("   const items = section.items.filter((item) => item.visible && item.rank > \(index));")
            }
        }
        let patch = lines.joined(separator: "\n")
        let files: [[String: Any]] = (0..<count).map { index in
            ["filename": "src/feed/module\(index)/GridSection\(index).tsx", "status": "modified", "sha": "blob\(index)",
             "additions": 130, "deletions": 43, "patch": patch]
        }
        return try! JSONSerialization.data(withJSONObject: [files])
    }
}

/// Logs who asks the window's SwiftUI host to update constraints while scrolling.
final class TracingHost<Content: View>: NSHostingView<Content> {
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if newValue && TraceState.tracing && TraceState.logged < 3 {
                TraceState.logged += 1
                print("TRACE needsUpdateConstraints\n" + Thread.callStackSymbols.prefix(28).joined(separator: "\n"))
            }
            super.needsUpdateConstraints = newValue
        }
    }
}

enum TraceState {
    nonisolated(unsafe) static var tracing = false
    nonisolated(unsafe) static var logged = 0
}
