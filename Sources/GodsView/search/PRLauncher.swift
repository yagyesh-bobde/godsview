import SwiftUI
import GitHubCore

@MainActor final class PRLauncher {
    private final class Panel: NSPanel {
        private var dismissing = false
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func resignKey() {
            super.resignKey()
            if isVisible { orderOut(nil) }
        }
        override func orderOut(_ sender: Any?) {
            guard !dismissing else { return }
            dismissing = true
            super.orderOut(sender)
            contentView = nil
            dismissing = false
        }
    }
    private var panel: Panel?
    private var presentation = 0

    func toggle(store: Workspace, open: @escaping (InboxItem) -> Void, canOpen: @escaping () -> Bool) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let width = min(700, bounds.width - 32), height = min(420, bounds.height - 32)
        let frame = NSRect(x: bounds.midX - width / 2, y: min(bounds.maxY - height - 8, bounds.midY - height * 0.32), width: width, height: height)
        let panel = self.panel ?? Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        presentation += 1
        let current = presentation
        self.panel = panel
        panel.setFrame(frame, display: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: PRLauncherView(store: store, canOpen: canOpen, open: { [weak self, weak panel] item in
            guard self?.presentation == current, panel?.isVisible == true else { return }
            panel?.orderOut(nil)
            open(item)
        }, dismiss: { [weak panel] in panel?.orderOut(nil) }).frame(width: width, height: height))
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }
}

struct PRLauncherView: View {
    let store: Workspace
    let canOpen: () -> Bool
    let open: (InboxItem) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var cursor = 0
    @State private var pending: Task<Void, Never>?
    @State private var error: String?
    @State private var inputFocused = false

    var body: some View {
        let link = PullRequestLink(query)
        let hits = link == nil ? PRMatch.rankExact(store.launcherResults(query), query: query) : []
        let shape = RoundedRectangle(cornerRadius: Radius.panel + 2, style: .continuous)
        // The results area fits its rows (up to the panel), so a single match or a pasted
        // link covers less of the desktop. The panel around it is transparent.
        let rows = link != nil ? 1 : max(1, hits.count)
        let maxListHeight: CGFloat = error == nil ? 322 : 268
        let listHeight = min(CGFloat(rows) * 47 + 40, maxListHeight)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: link == nil ? "magnifyingglass" : "link").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(link != nil || inputFocused ? Ink.blue : Ink.dim).frame(width: 22)
                PaletteInput(text: $query, placeholder: "Search pull requests or paste a GitHub PR link…", fontSize: 18,
                             move: { cursor = max(0, min(hits.count - 1, cursor + $0)) },
                             submit: { choose(link, hits: hits) }, cancel: dismiss, focus: { inputFocused = $0 })
                if pending != nil { ProgressView().controlSize(.small) }
                else { Keycap("esc") }
            }.padding(.horizontal, 20).frame(height: 58)
            SearchFocusRule(focused: inputFocused)
            if let error {
                // Show errors directly under the search field so results never push them out of view.
                let banner = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.red)
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Ink.text)
                        .lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { self.error = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.dim)
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Ink.red.opacity(0.12), in: banner)
                .overlay(banner.strokeBorder(Ink.red.opacity(0.28)))
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if let link {
                            PaletteGroupHeader(title: "Open link", first: true)
                            Button { choose(link, hits: []) } label: {
                                PaletteRow(icon: "arrow.up.forward.app", iconTint: Ink.blue,
                                           title: "Open \(link.nameWithOwner) #\(link.number)",
                                           subtitle: "Uses the first connected account that can read it", detail: "", selected: true)
                            }.buttonStyle(.plain)
                        } else {
                            PaletteGroupHeader(title: query.isEmpty ? "Recent pull requests" : "Pull requests", first: true)
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, item in
                                Button { cursor = index; openItem(item) } label: {
                                    PaletteRow(icon: item.pr.isDraft ? "pencil.circle" : "arrow.triangle.pull",
                                               iconTint: item.pr.isDraft ? Ink.faint : Ink.green,
                                               title: (item.pr.isDraft ? "Draft: " : "") + item.pr.title, highlight: query,
                                               subtitle: "\(item.pr.repository.nameWithOwner) #\(item.pr.number)"
                                                   + (PRMatch.hiddenContext(item, query: query).map { " · " + $0 } ?? ""),
                                               detail: item.account, selected: index == cursor)
                                }.buttonStyle(.plain).id(item.id)
                                    .onHover { if $0 { cursor = index } }
                            }
                            if hits.isEmpty {
                                Text(store.refreshing ? "Syncing pull requests…" : "No matching pull requests")
                                    .font(.callout).foregroundStyle(Ink.dim).frame(maxWidth: .infinity).padding(.vertical, 32)
                            }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.onChange(of: cursor) { _, i in if hits.indices.contains(i) { proxy.scrollTo(hits[i].id) } }
                    .onChange(of: query) { cursor = 0; pending?.cancel(); pending = nil; error = nil
                        if let first = hits.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
            }.frame(height: listHeight)
                .overlay(alignment: .bottom) { if hits.count > 6 { ScrollFade(color: Ink.surface) } }
            WorkspaceRule()
            PaletteFooter {
                HStack(spacing: 0) {
                    Text("Gods").fontWeight(.semibold).foregroundStyle(Ink.text)
                    Text("View").foregroundStyle(Ink.dim)
                }
            } trailing: {
                HStack(spacing: 5) { Keycap("↑"); Keycap("↓"); Text("Navigate") }
                HStack(spacing: 5) { Keycap("↵"); Text(link == nil ? "Open PR" : "Open link") }
            }
        }.foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
            .background(Ink.surface.opacity(0.97), in: shape)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .frame(maxHeight: .infinity, alignment: .top)
            // The panel's shadow follows the visible surface as it grows or shrinks.
            .onChange(of: listHeight) { DispatchQueue.main.async { NSApp.keyWindow?.invalidateShadow() } }
            .onChange(of: error) { DispatchQueue.main.async { NSApp.keyWindow?.invalidateShadow() } }
            .onDisappear { pending?.cancel() }
    }

    private func openItem(_ item: InboxItem) {
        guard canOpen() else { error = "Finish the open sheet in GodsView before switching PRs."; return }
        open(item)
    }

    private func choose(_ link: PullRequestLink?, hits: [InboxItem]) {
        guard pending == nil else { return }
        if let link {
            error = nil
            pending = Task {
                do {
                    let item = try await store.resolve(link)
                    guard !Task.isCancelled else { return }
                    pending = nil
                    openItem(item)
                } catch {
                    guard !Task.isCancelled else { return }
                    pending = nil
                    self.error = error.localizedDescription
                }
            }
        } else if hits.indices.contains(cursor) { openItem(hits[cursor]) }
    }
}
