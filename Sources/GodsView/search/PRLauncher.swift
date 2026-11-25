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
        let width = min(700, bounds.width - 32), height = min(398, bounds.height - 32)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                PaletteInput(text: $query, placeholder: "Search pull requests or paste a GitHub PR link…", fontSize: 17,
                             move: { cursor = max(0, min(hits.count - 1, cursor + $0)) },
                             submit: { choose(link, hits: hits) }, cancel: dismiss)
                if pending != nil { ProgressView().controlSize(.small) }
                else { Text("esc").font(.caption.monospaced()).foregroundStyle(Ink.faint) }
            }.padding(.horizontal, 18).frame(height: 60)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let link {
                            Button { choose(link, hits: []) } label: {
                                Label("Open \(link.nameWithOwner) #\(link.number)", systemImage: "arrow.up.forward.app")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(Ink.selection, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        } else {
                            Text(query.isEmpty ? "Recent pull requests" : "Pull requests").font(.caption.weight(.semibold))
                                .foregroundStyle(Ink.dim).padding(.horizontal, 10).padding(.vertical, 5)
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, item in
                                Button { cursor = index; openItem(item) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.triangle.pull").foregroundStyle(Ink.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.pr.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                                            Text("\(item.pr.repository.nameWithOwner) #\(item.pr.number)")
                                                .font(.caption).foregroundStyle(Ink.dim)
                                        }
                                        Spacer()
                                        Text(item.account).lineLimit(1).font(.caption).foregroundStyle(Ink.dim)
                                    }.padding(.horizontal, 10).frame(height: 43)
                                        .background(index == cursor ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(item.id)
                            }
                            if hits.isEmpty {
                                Text(store.refreshing ? "Syncing pull requests…" : "No matching pull requests")
                                    .font(.callout).foregroundStyle(Ink.dim).padding(10)
                            }
                        }
                        if let error { Text(error).font(.callout).foregroundStyle(Ink.red).padding(10).textSelection(.enabled) }
                    }.padding(7)
                }.onChange(of: cursor) { _, i in if hits.indices.contains(i) { proxy.scrollTo(hits[i].id) } }
                    .onChange(of: query) { cursor = 0; pending?.cancel(); pending = nil; error = nil
                        if let first = hits.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
            }
            Divider()
            HStack {
                Text("GodsView").fontWeight(.semibold)
                Spacer()
                Text("↑ ↓  Navigate")
                Text("↵  Open PR")
            }.font(.caption).foregroundStyle(Ink.dim).padding(.horizontal, 16).frame(height: 33)
        }.foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.18)))
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
