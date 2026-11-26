import AppKit
import SwiftUI
import Testing
@testable import GitHubCore
@testable import GodsView

/// Renders the real workspace window with synthetic pull requests so UI changes can be
/// reviewed without a GitHub account or the installed app. It only runs when asked:
///
///     GODSVIEW_RENDER_DIR=/tmp/godsview-renders swift test --filter renderWorkspaceFixtures
///
/// Every name, repository, branch and patch below is invented.
@MainActor @Test func renderWorkspaceFixtures() async throws {
    guard let directory = ProcessInfo.processInfo.environment["GODSVIEW_RENDER_DIR"] else { return }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // A window zoomed to fill this Mac's desktop (menu bar and Dock excluded).
    let desktop = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 949)
    let scenarios: [(name: String, size: CGSize, setup: @MainActor (Workspace) -> Void)] = [
        ("code-maximized", desktop, { _ in }),
        ("code-folded-maximized", desktop, { store in
            store.review.automaticallyFoldHeader = false
            store.review.headerCollapsed = true
        }),
        ("summary-maximized", desktop, { store in store.review.tab = .summary }),
        ("discussion-maximized", desktop, { store in store.review.tab = .discussion }),
        ("code-wide", CGSize(width: 1440, height: 900), { _ in }),
        ("code-scrolled-wide", CGSize(width: 1440, height: 900), { _ in }),
        ("code-midscroll-wide", CGSize(width: 1440, height: 900), { _ in }),
        ("code-compact", CGSize(width: 960, height: 640), { _ in }),
        ("code-collapsed-files-compact", CGSize(width: 960, height: 640), { store in store.review.toggleAllFiles() }),
        ("code-t3-wide", CGSize(width: 1440, height: 900), { store in store.review.toggleT3() }),
        ("code-t3-compact", CGSize(width: 960, height: 640), { store in store.review.toggleT3() }),
        ("code-t3-minimum", CGSize(width: 855, height: 640), { store in store.review.toggleT3() }),
        ("code-folded-wide", CGSize(width: 1440, height: 900), { store in
            store.review.automaticallyFoldHeader = false
            store.review.headerCollapsed = true
        }),
        ("summary-wide", CGSize(width: 1440, height: 900), { store in store.review.tab = .summary }),
        ("approved-summary-compact", CGSize(width: 960, height: 640), { store in
            store.selection = store.items.first { $0.pr.number == 477 }?.id
            store.review.tab = .summary
        }),
        ("discussion-compact", CGSize(width: 960, height: 640), { store in store.review.tab = .discussion }),
        ("code-no-sidebars-compact", CGSize(width: 960, height: 640), { store in
            store.sidebarVisible = false
            store.review.showTree = false
        }),
    ]
    for scenario in scenarios {
        let store = Workspace(client: GitHubClient(cli: FixtureCLI()))
        await store.refresh()
        store.selection = store.items.first { $0.pr.number == 482 }?.id
        let controls = WindowControls()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: scenario.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let root = FixtureRoot(store: store, controls: controls)
        .foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowReader(controls: controls))
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: scenario.size), display: false)
        window.orderFrontRegardless()
        try await settle(seconds: 1.2)
        scenario.setup(store)
        // Distances from the very top: past the PR header, and halfway through it.
        if let distance: CGFloat = ["code-scrolled-wide": 190, "code-midscroll-wide": 42][scenario.name] {
            let scroll = try #require(findDiffScroll(window.contentView))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: distance - scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        try await settle(seconds: 0.9)
        try snapshot(window, to: output.appendingPathComponent(scenario.name + ".png"))
        window.orderOut(nil)
        window.close()
    }

    // The palette and the floating launcher, shown over a plain backdrop like on screen.
    let store = Workspace(client: GitHubClient(cli: FixtureCLI()))
    await store.refresh()
    store.selection = store.items.first { $0.pr.number == 482 }?.id
    await store.review.loadFiles(store.selected!, client: store.client)
    await store.review.loadCommits(store.selected!, client: store.client)
    try await renderPanel(SearchPalette(mode: .global, store: store) {}, size: CGSize(width: 760, height: 520),
                          to: output.appendingPathComponent("palette-global.png"))
    try await renderPanel(SearchPalette(mode: .files, store: store) {}, size: CGSize(width: 760, height: 520),
                          to: output.appendingPathComponent("palette-files.png"))
    let reply = """
    The tracker counts a grid row once its `from`/`to` slice is inside the draw window, so a tall grid reports each row as it scrolls in.

    - `useGridRowViews.ts` keys rows by `section + row`, so re-renders never double count.
    - Cards with no `card_id` are skipped before the settle timer starts.

    One gap: the 2 × 3 fallback has no test yet.
    """
    let conversation = try JSONDecoder().decode(T3Conversation.self, from: JSONSerialization.data(withJSONObject: [
        "thread": ["status": "completed", "model": "claude-opus-5-5", "link": "t3://thread/fixture"],
        "messages": [
            ["role": "user", "text": "Answer the question.\nPR: https://github.com/orbit-labs/orbit-mobile/pull/482\n\nQuestion:\nHow does a tall card grid avoid over-reporting impressions?"],
            ["role": "assistant", "text": reply],
            ["role": "user", "text": "Is the fallback covered anywhere else?"],
        ],
    ]))
    try await renderPanel(T3Pane(item: store.selected!, review: store.review,
                                 fixture: (T3ThreadRef(threadId: "fixture", title: "How does a tall card grid avoid…"), conversation))
        .frame(width: 380, height: 640), size: CGSize(width: 380, height: 640),
                          to: output.appendingPathComponent("t3-pane.png"))
    try await renderPanel(Form { T3Settings(store: store) }.formStyle(.grouped).frame(width: 520, height: 420),
                          size: CGSize(width: 560, height: 460), to: output.appendingPathComponent("settings-t3.png"))
    try await renderPanel(PRLauncherView(store: store, canOpen: { true }, open: { _ in }, dismiss: {})
        .frame(width: 700, height: 420), size: CGSize(width: 820, height: 540),
                          to: output.appendingPathComponent("launcher.png"))
}

/// Reads the header height inside `body`, like the app's scene, so it follows the traffic lights.
struct FixtureRoot: View {
    let store: Workspace
    let controls: WindowControls
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(store: store, height: controls.headerHeight)
            InboxView(store: store, showAccounts: .constant(false), controls: controls)
        }
    }
}

@MainActor private func renderPanel(_ content: some View, size: CGSize, to url: URL) async throws {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ZStack { Color(white: 0.16); content }
        .foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark))
    window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), display: false)
    window.orderFrontRegardless()
    try await settle(seconds: 0.8)
    guard let view = window.contentView else { return }
    useOverlayScrollers(view)
    view.layoutSubtreeIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CLIError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: image)
    try image.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
    window.close()
}

@MainActor func settle(seconds: Double) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        pumpRunLoop()
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// SwiftUI and AppKit schedule their layout and drawing on the main run loop.
@MainActor func pumpRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

/// Renders use overlay scrollers (the trackpad default) so a briefly connected mouse does not
/// change the layout between runs.
@MainActor func useOverlayScrollers(_ view: NSView) {
    (view as? NSScrollView)?.scrollerStyle = .overlay
    for child in view.subviews { useOverlayScrollers(child) }
}

@MainActor private func snapshot(_ window: NSWindow, to url: URL) throws {
    // The frame view includes the traffic lights, so their alignment can be checked too.
    guard let frame = window.contentView?.superview else { throw CLIError("No window frame view") }
    useOverlayScrollers(frame)
    frame.layoutSubtreeIfNeeded()
    frame.layoutSubtreeIfNeeded()
    frame.displayIfNeeded()
    guard let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw CLIError("No bitmap") }
    frame.cacheDisplay(in: frame.bounds, to: image)
    guard let data = image.representation(using: .png, properties: [:]) else { throw CLIError("No PNG data") }
    try data.write(to: url)
}

struct FixtureCLI: CommandRunning {
    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        let joined = arguments.joined(separator: " ")
        if arguments.starts(with: ["auth", "status"]) {
            return Data(#"{"hosts":{"github.com":[{"login":"sam-rivera","active":true,"state":"success"}]}}"#.utf8)
        }
        if arguments.starts(with: ["auth", "token"]) { return Data("fixture-token".utf8) }
        if joined.contains("query Inbox") { return Self.inbox }
        if joined.contains("query History") { return Self.history }
        if joined.contains("query ViewedFiles") { return Self.viewed }
        if joined.contains("query Conversation") { return Self.conversation }
        if joined.contains("/pulls/482/files") { return Self.files }
        if joined.contains("/files") { return Data("[[]]".utf8) }
        throw CLIError("Fixture has no response for \(arguments.prefix(4))")
    }

    private static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    private static func pr(_ number: Int, _ title: String, repo: String, author: String, minutesAgo: Int,
                           draft: Bool = false, decision: String? = "REVIEW_REQUIRED", files: Int = 3,
                           additions: Int = 42, deletions: Int = 7) -> [String: Any] {
        let updated = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 - Double(minutesAgo * 60)))
        return [
            "id": "PR_\(number)", "number": number, "title": title,
            "url": "https://github.com/\(repo)/pull/\(number)", "updatedAt": updated, "state": "OPEN",
            "isDraft": draft, "reviewDecision": decision as Any, "headRefName": "feat/dynamic-card-grid",
            "baseRefName": "main", "headRefOid": "9f3c2ab", "baseRefOid": "41d07e0",
            "body": number == 482 ? Self.body : "Small fix.", "bodyText": "Small fix.",
            "additions": additions, "deletions": deletions, "changedFiles": files,
            "author": ["login": author], "repository": ["nameWithOwner": repo],
            "labels": ["nodes": number == 482 ? [["name": "feed"], ["name": "needs-qa"]] : []],
        ]
    }

    private static let body = """
    Sizes the card grid from the `layout_config` the backend sends, instead of the fixed 2 × 3 grid.

    ## Changes
    - Read `rows` and `columns` from the section payload, falling back to 2 × 3.
    - Count impressions per grid row so tall grids do not over-report.
    - Document the firing rule in `docs/analytics/card-viewed.md`.

    ## Testing
    Ran the feed on a small phone and a tablet with 1 × 4, 2 × 3 and 3 × 3 configs.
    """

    static let inbox: Data = {
        let nodes: [[String: Any]] = [
            pr(482, "feat(feed): size the card grid from backend layout_config", repo: "orbit-labs/orbit-mobile",
               author: "sam-rivera", minutesAgo: 5, files: 9, additions: 371, deletions: 83),
            pr(481, "fix(feed): pause banner autoplay when the tab is hidden", repo: "orbit-labs/orbit-mobile",
               author: "sam-rivera", minutesAgo: 30),
            pr(477, "fix(chat): keep the composer above the Android keyboard", repo: "orbit-labs/orbit-mobile",
               author: "jules-park", minutesAgo: 90, decision: "APPROVED"),
            pr(470, "chore(core): replace deprecated validation helpers", repo: "orbit-labs/orbit-mobile",
               author: "sam-rivera", minutesAgo: 200, draft: true),
            pr(58, "Release android v1.0.37", repo: "orbit-labs/orbit-companion", author: "sam-rivera", minutesAgo: 400),
            pr(2204, "feat(profile): enable language row and card toggle", repo: "orbit-labs/orbit-api",
               author: "dev-okafor", minutesAgo: 700, decision: "CHANGES_REQUESTED"),
            pr(132, "feat(payments): public payment link page", repo: "orbit-labs/orbit-web",
               author: "sam-rivera", minutesAgo: 900),
            pr(123, "feat(nav): ⌘B pins the desktop rail", repo: "orbit-labs/orbit-web", author: "jules-park", minutesAgo: 1000),
        ]
        let page: [String: Any] = ["nodes": nodes, "pageInfo": ["hasNextPage": false]]
        let empty: [String: Any] = ["nodes": [], "pageInfo": ["hasNextPage": false]]
        return json(["data": ["reviews": page, "authored": empty, "assigned": empty]])
    }()

    static let history = json([["data": ["node": ["commits": ["nodes": [
        ["commit": ["oid": "1a2b3c4d5e", "messageHeadline": "Read grid size from layout_config"]],
        ["commit": ["oid": "2b3c4d5e6f", "messageHeadline": "Count impressions per grid row"]],
        ["commit": ["oid": "9f3c2ab001", "messageHeadline": "Document the firing rule"]],
    ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]]]])

    private static let paths = [
        "docs/analytics/card-viewed.md", "docs/feed/grid-system.md", "docs/feed/section-contract.md",
        "src/feed/components/cards/GridCard.styles.ts", "src/feed/components/cards/GridCard.tsx",
        "src/feed/components/CardGridSection.tsx", "src/feed/hooks/useGridRowViews.ts",
        "src/feed/utils/renderedRows.ts", "src/feed/utils/sectionViews.ts",
    ]

    static let viewed = json([["data": ["node": ["files": ["nodes": paths.enumerated().map { index, path in
        ["path": path, "viewerViewedState": index == 1 ? "VIEWED" : "UNVIEWED"]
    }, "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]]]])

    static let conversation = json(["data": ["node": ["comments": ["nodes": [
        ["id": "c1", "author": ["login": "jules-park"], "createdAt": "2026-09-21T10:12:00Z",
         "body": "Looks good. Can we keep the 2 × 3 fallback covered by a test?", "bodyText": ""],
        ["id": "c2", "author": ["login": "sam-rivera"], "createdAt": "2026-09-21T11:40:00Z",
         "body": "Added `useGridRowViews.test.ts` with the fallback case.", "bodyText": ""],
    ]]]]])

    static let files: Data = {
        let markdown = """
        @@ -8,14 +8,15 @@
         outer list rows it DRAWS (layout ∩ window ± 250)  ->  row gate
         inner lists: cards with any part on screen (1%)   ->  cards
         carousels: settled centre + neighbours that peek  ->  cards
        +card grids: each grid row inside the same window  ->  cards
                     \\                            /
           SectionViews (one per tab)  ->  core views.ts: settle timer -> Set dedupe -> idle flush
         ```

         - Core: `src/core/events/views.ts` (flag + settle time, session `Set`, timers, scroll pause).
        -- Drawn rows: `src/feed/utils/renderedRows.ts` reads `getLayout` / `getLastScrollOffset`.
        -- Hooks: `useSectionViews` (FeedScene), `useViews.ts` (`useViewability`, `useViewReporter`).
        +- Drawn rows: `src/feed/utils/renderedRows.ts` reads `getLayout` / `getLastScrollOffset`.
        +- Hooks: `useSectionViews` (FeedScene), `useViews.ts` (`useViewability`, `useViewReporter`).
         - Shared props builder for click and view: `src/feed/utils/cardEvents.ts`.

         ## Firing rule
        @@ -33,16 +34,19 @@ carousels: settled centre + neighbours that peek
         - **Once per app session.** Key = `section (or tab) + card`. Memory only; cleared on logout.
         - **Flag off = zero cost.** No tracker, no list props, no geometry work.
        -- **Static grids** (banner, category grid, 2x2 / 2x3) count only the cards they draw.
        +- **Static grids** (banner, category grid, 2x2 / 2x3) count only the cards they draw.
        +- **Card grids count per grid row.** With up to 6 rows a grid can be taller than the screen.
         - **Carousel ranks** are the real data position, never the loop-copy index.
        """
        let code = """
        @@ -1,18 +1,26 @@
         import { useMemo } from 'react';
         import type { SectionPayload } from '../types';
        +import { clampGrid } from '../utils/layout';

         const DEFAULT_ROWS = 2;
         const DEFAULT_COLUMNS = 3;

        -export function useGridSize(section: SectionPayload) {
        -  return { rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS };
        +export function useGridSize(section: SectionPayload) {
        +  return useMemo(() => {
        +    const config = section.layout_config;
        +    if (!config) return { rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS };
        +    // Never render more than 6 rows; the backend can send anything.
        +    return clampGrid(config.rows, config.columns, { maxRows: 6, maxColumns: 4 });
        +  }, [section.layout_config]);
         }
        """
        let files: [[String: Any]] = paths.enumerated().map { index, path in
            let isDoc = path.hasSuffix(".md")
            return ["filename": path, "status": index == 6 ? "added" : "modified", "sha": "blob\(index)",
                    "additions": isDoc ? 8 : 12, "deletions": isDoc ? 4 : 2, "patch": isDoc ? markdown : code]
        }
        return json([files])
    }()
}
