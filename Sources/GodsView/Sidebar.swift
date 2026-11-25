import SwiftUI
import GitHubCore

struct Sidebar: View {
    @Bindable var store: Workspace
    @Binding var showAccounts: Bool
    @State private var collapsed = Set<String>()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The review the header last animated for. Picking another PR swaps in a fresh review
    /// whose header starts expanded; the new detail pane appears without animating, so the
    /// sidebar must snap too or the two headers drift apart for a moment.
    @State private var animatedReview: ObjectIdentifier?
    @State private var holdingCommand = false
    @State private var shortcuts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            let groups = Dictionary(grouping: store.visible) { $0.pr.repository.nameWithOwner }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if let linked = store.linkedRow {
                                Text("Opened by link").font(.caption).foregroundStyle(Ink.dim).padding(.leading, 8)
                                row(linked)
                            }
                            ForEach(groups.keys.sorted(), id: \.self) { repo in
                                let entries = groups[repo] ?? []
                                Button {
                                    if !collapsed.insert(repo).inserted { collapsed.remove(repo) }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: collapsed.contains(repo) ? "chevron.right" : "chevron.down").font(.system(size: 8))
                                        Image(systemName: "folder")
                                        Text(repo).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.dim).padding(.horizontal, 7)
                                        .frame(height: 25).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button { store.hideRepository(repo) } label: {
                                            Label("Hide Repository", systemImage: "eye.slash")
                                        }
                                    }
                                if !collapsed.contains(repo) {
                                    ForEach(entries) { item in row(item).transition(.opacity) }
                                }
                            }
                            if store.visible.isEmpty && store.linkedRow == nil {
                                Text(store.refreshing ? "Syncing pull requests…" : "No pull requests in this view")
                                    .font(.caption).foregroundStyle(Ink.dim).padding(10)
                            }
                        }.padding(5)
                            .animation(Motion.layout(reduceMotion), value: collapsed)
                    }.coordinateSpace(name: "PR viewport")
                        .onPreferenceChange(SidebarRowFrames.self) { frames in
                            shortcuts = SidebarRowFrames.shortcuts(frames, height: viewport.size.height)
                        }
                        .onChange(of: store.selection) { _, id in
                        if let item = store.selected { collapsed.remove(item.pr.repository.nameWithOwner) }
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                Menu {
                    Button("All accounts") { store.scope = nil }
                    ForEach(store.accounts) { account in Button(account.login) { store.scope = account.login } }
                    Divider()
                    Button("Manage accounts…") { showAccounts = true }
                } label: {
                    Label(store.scope ?? "All accounts", systemImage: "person.crop.circle")
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if store.refreshing { ProgressView().controlSize(.mini) }
                else if !store.issues.isEmpty {
                    toolIcon("exclamationmark.triangle", "GitHub sync status") { showAccounts = true }
                }
                SettingsLink { Image(systemName: "gearshape").frame(width: 21, height: 23) }
                    .buttonStyle(.plain).help("Settings (⌘,)")
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 38)
            if store.scope.map(store.limited.contains) ?? !store.limited.isEmpty {
                Text("Latest 50 per queue").font(.caption2).foregroundStyle(Ink.dim).padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        // Same curves and keys as the detail header, so both sides of the split fold
        // their rows together and the hairlines stay lined up mid-animation.
        .animation(sameReview ? Motion.layout(reduceMotion) : nil, value: store.review.headerCollapsed)
        .animation(sameReview ? Motion.swap(reduceMotion) : nil, value: store.review.tab)
        .onChange(of: ObjectIdentifier(store.review), initial: true) { _, id in animatedReview = id }
        .background(Ink.rail)
            .background(SidebarShortcuts(held: { holdingCommand = $0 }, select: { number in
                guard shortcuts.indices.contains(number - 1) else { return false }
                store.selection = shortcuts[number - 1]
                return true
            }))
    }

    private var sameReview: Bool { animatedReview == ObjectIdentifier(store.review) }

    @ViewBuilder private var header: some View {
        let code = store.review.tab == .code
        let expanded = store.selected == nil || (code && !store.review.headerCollapsed)
        if expanded {
            VStack(spacing: 0) {
                Button { store.palette = .global } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Search workspace")
                        Spacer()
                        Text("⌘ K").font(.caption.monospaced())
                    }.font(.system(size: 12)).foregroundStyle(Ink.dim).padding(.horizontal, 8).frame(height: 26)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.line))
                }.buttonStyle(.plain).padding(.horizontal, 9).headerRow(.context, rule: false)
                HStack {
                    queuePicker(compact: false)
                    Spacer()
                    Text("\(store.visible.count)").font(.caption.monospacedDigit()).foregroundStyle(Ink.faint)
                    refreshButton
                }.padding(.horizontal, 12).headerRow(.navigation)
            }.transition(Motion.header(reduceMotion))
        }
        HStack(spacing: 6) {
            if expanded {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Ink.faint)
            } else {
                toolIcon("magnifyingglass", "Search workspace (⌘K)") { store.palette = .global }
                queuePicker(compact: true)
            }
            TextField("Filter pull requests…", text: $store.query).textFieldStyle(.plain)
                .accessibilityLabel("Filter pull requests")
            if !store.query.isEmpty { toolIcon("xmark", "Clear filter") { store.query = "" } }
            if !expanded { refreshButton }
        }.font(.caption).padding(.horizontal, expanded ? 14 : 8)
            .headerRow(code || expanded ? .controls : .navigation)
    }

    private var refreshButton: some View {
        toolIcon("arrow.clockwise", "Refresh inbox") { Task { await store.refresh() } }.disabled(store.refreshing)
    }

    private func queuePicker(compact: Bool) -> some View {
        Menu {
            ForEach(Queue.allCases, id: \.self) { queue in
                Button { store.queue = queue } label: { Label(queue.title, systemImage: queue.symbol) }
            }
        } label: {
            HStack(spacing: 4) {
                if compact { Image(systemName: store.queue.symbol) }
                else { Text(store.queue == .inbox ? "Pull requests" : store.queue.title).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(.system(size: 12, weight: .semibold)).help(store.queue.title)
            .accessibilityLabel("Pull request queue, " + store.queue.title)
    }

    private func row(_ item: InboxItem) -> some View {
        Button { store.selection = item.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 11)).foregroundStyle(item.pr.isDraft ? Ink.faint : Ink.green)
                    .frame(width: 13).padding(.top, 2)
                    .overlay {
                        if holdingCommand, let index = shortcuts.firstIndex(of: item.id) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Ink.text).frame(width: 19, height: 18).background(Ink.selection, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.dim))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.pr.title).lineLimit(1).truncationMode(.tail).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 5) {
                        Text("#\(item.pr.number)").font(.system(size: 10, design: .monospaced))
                        Text(item.account).lineLimit(1)
                        Spacer(minLength: 0)
                        if store.saved.contains(item.id) { Image(systemName: "bookmark.fill") }
                    }.font(.system(size: 10)).foregroundStyle(Ink.faint)
                }
            }.padding(.leading, 15).padding(.trailing, 8).padding(.vertical, 6)
                .background(store.selection == item.id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(item.pr.title).id(item.id)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SidebarRowFrames.self, value: [item.id: geometry.frame(in: .named("PR viewport"))])
            })
    }
}
