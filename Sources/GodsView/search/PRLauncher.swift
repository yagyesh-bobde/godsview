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

    var body: some View {
        let link = PullRequestLink(query)
        let hits = link == nil ? store.launcherResults(query) : []
        let shape = RoundedRectangle(cornerRadius: Radius.panel + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: link == nil ? "magnifyingglass" : "link").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(link == nil ? Ink.dim : Ink.blue).frame(width: 22)
                PaletteInput(text: $query, placeholder: "Search pull requests or paste a GitHub PR link…", fontSize: 18,
                             move: { cursor = max(0, min(hits.count - 1, cursor + $0)) },
                             submit: { choose(link, hits: hits) }, cancel: dismiss)
                if pending != nil { ProgressView().controlSize(.small) }
                else { Keycap("esc") }
            }.padding(.horizontal, 20).frame(height: 58)
            WorkspaceRule()
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
                                               title: item.pr.title,
                                               subtitle: "\(item.pr.repository.nameWithOwner) #\(item.pr.number)",
                                               detail: item.account, selected: index == cursor)
                                }.buttonStyle(.plain).id(item.id)
                                    .onHover { if $0 { cursor = index } }
                            }
                            if hits.isEmpty {
                                Text(store.refreshing ? "Syncing pull requests…" : "No matching pull requests")
                                    .font(.callout).foregroundStyle(Ink.dim).frame(maxWidth: .infinity).padding(.vertical, 32)
                            }
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Ink.red)
                                .padding(10).textSelection(.enabled)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.onChange(of: cursor) { _, i in if hits.indices.contains(i) { proxy.scrollTo(hits[i].id) } }
                    .onChange(of: query) { cursor = 0; pending?.cancel(); pending = nil; error = nil
                        if let first = hits.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
            }.overlay(alignment: .bottom) { if hits.count > 6 { ScrollFade(color: Ink.surface) } }
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
            .overlay(shape.strokeBorder(Color.white.opacity(0.14)))
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
