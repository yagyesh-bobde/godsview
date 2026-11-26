import AppKit
import SwiftUI
import Testing
@testable import GitHubCore
@testable import GodsView

/// Captures the window every few points while scrolling down from the top and back, so the
/// header hand-off can be checked frame by frame. Runs only when asked:
///     GODSVIEW_SCROLL_FRAMES=/tmp/frames swift test --filter captureScrollFrames
@MainActor @Test func captureScrollFrames() async throws {
    guard let directory = ProcessInfo.processInfo.environment["GODSVIEW_SCROLL_FRAMES"] else { return }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let store = Workspace(client: GitHubClient(cli: FixtureCLI()))
    await store.refresh()
    store.selection = store.items.first { $0.pr.number == 482 }?.id
    let controls = WindowControls()
    let size = CGSize(width: 1440, height: 900)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: FixtureRoot(store: store, controls: controls)
        .foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top).background(WindowReader(controls: controls)))
    window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), display: false)
    window.orderFrontRegardless()
    try await settle(seconds: 1.5)
    let scroll = try #require(findScroll(window.contentView))
    let distances = Array(stride(from: 0, through: 120, by: 12)) + Array(stride(from: 108, through: 0, by: -12))
    for (index, distance) in distances.enumerated() {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(distance) - scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        try await settle(seconds: 0.12)
        guard let frame = window.contentView?.superview else { continue }
        useOverlayScrollers(frame)
        frame.displayIfNeeded()
        guard let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
        frame.cacheDisplay(in: frame.bounds, to: image)
        try image.representation(using: .png, properties: [:])?
            .write(to: output.appendingPathComponent(String(format: "%02d-%03d.png", index, distance)))
    }
    window.orderOut(nil)
}

@MainActor private func findScroll(_ view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    if let scroll = view as? NSScrollView, scroll.documentView is DiffTable { return scroll }
    for child in view.subviews { if let found = findScroll(child) { return found } }
    return nil
}
