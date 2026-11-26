import AppKit
import SwiftUI
import Testing
@testable import GitHubCore
@testable import GodsView

/// Scrolls a large synthetic PR in the real workspace window, down from the top and back up,
/// and reports how long each step takes on the main thread. Runs only when asked:
///
///     GODSVIEW_SCROLL_BENCH=1 swift test --filter scrollLargePullRequest
@MainActor @Test func scrollLargePullRequest() async throws {
    guard ProcessInfo.processInfo.environment["GODSVIEW_SCROLL_BENCH"] != nil else { return }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let size = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 949)
    let store = Workspace(client: GitHubClient(cli: BenchCLI()))
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
    window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
        WorkspaceToolbar(store: store, height: controls.headerHeight)
        InboxView(store: store, showAccounts: .constant(false), controls: controls)
    }
    .foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
    .ignoresSafeArea(.container, edges: .top)
    .background(WindowReader(controls: controls)))
    window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), display: false)
    window.orderFrontRegardless()
    try await settle(seconds: 2)

    guard let scroll = findDiffScroll(window.contentView) else { throw CLIError("No diff scroll view") }
    let step: CGFloat = 60  // a brisk trackpad flick moves roughly this far per frame
    var frames: [Double] = []
    func frame(to y: CGFloat) {
        let start = CACurrentMediaTime()
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        RunLoop.main.run(until: Date())
        window.displayIfNeeded()
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms > 12 { print(String(format: "SCROLLBENCH slow %.1fms at y=%.0f", ms, y)) }
        frames.append(ms)
    }
    if ProcessInfo.processInfo.environment["GODSVIEW_SCROLL_BENCH"] == "top" {
        // Bounce across the header fold point so a sampler sees mostly that work.
        for _ in 0..<40 {
            for y in stride(from: 0, through: 240, by: 60) { frame(to: CGFloat(y)) }
            for y in stride(from: 240, through: 0, by: -60) { frame(to: CGFloat(y)) }
            for _ in 0..<20 { frame(to: 0); try await Task.sleep(for: .milliseconds(8)) }
        }
        return
    }
    // Two passes: the first touches every row cold, the second is warm.
    for pass in 1...2 {
        frames.removeAll()
        let bottom = min(6000, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        var y: CGFloat = 0
        while y < bottom { y += step; frame(to: min(y, bottom)) }
        while y > 0 { y -= step; frame(to: max(y, 0)) }
        // A short tail at the top lets any header animation finish inside the measurement.
        for _ in 0..<30 { frame(to: 0); try await Task.sleep(for: .milliseconds(8)) }
        let sorted = frames.sorted()
        let total = frames.reduce(0, +)
        let slow = frames.filter { $0 > 8.3 }.count
        print(String(format: "SCROLLBENCH pass %d: frames %d total %.1fms mean %.2fms p95 %.2fms max %.2fms over8ms %d",
                     pass, frames.count, total, total / Double(frames.count),
                     sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, slow))
    }
    window.orderOut(nil)
    window.close()
}

@MainActor private func findDiffScroll(_ view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    if let scroll = view as? NSScrollView, scroll.documentView is DiffTable { return scroll }
    for child in view.subviews { if let found = findDiffScroll(child) { return found } }
    return nil
}

/// The fixture PR, but with 40 files of about 300 lines each.
private struct BenchCLI: CommandRunning {
    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        if arguments.joined(separator: " ").contains("/pulls/482/files") { return Self.files }
        if arguments.joined(separator: " ").contains("query ViewedFiles") {
            return Data(#"[{"data":{"node":{"files":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]"#.utf8)
        }
        return try await FixtureCLI().run(arguments, token: token, input: input)
    }

    static let files: Data = {
        var lines = ["@@ -1,260 +1,300 @@"]
        for index in 0..<300 {
            switch index % 7 {
            case 0: lines.append("+  const value\(index) = clampGrid(config.rows, config.columns, { maxRows: 6 }); // row \(index)")
            case 1: lines.append("-  return { rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS, index: \(index) };")
            case 2: lines.append(" export function useGridSize\(index)(section: SectionPayload): GridSize {")
            case 3: lines.append("+    if (!section.layout_config) { return fallback(\"grid-\(index)\", 'cards'); }")
            default: lines.append("   const items = section.items.filter((item) => item.visible && item.rank > \(index));")
            }
        }
        let patch = lines.joined(separator: "\n")
        let files: [[String: Any]] = (0..<40).map { index in
            ["filename": "src/feed/module\(index)/GridSection\(index).tsx", "status": "modified", "sha": "blob\(index)",
             "additions": 130, "deletions": 43, "patch": patch]
        }
        return try! JSONSerialization.data(withJSONObject: [files])
    }()
}
