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
                                    HStack(spacing: 6) {
                                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                                            .rotationEffect(.degrees(collapsed.contains(repo) ? 0 : 90))
                                            .frame(width: 10)
                                        Text(repo).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        Text("\(entries.count)").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                            .foregroundStyle(Ink.faint)
                                    }.font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ink.dim).padding(.leading, 9).padding(.trailing, 8)
                                        .frame(height: 26).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(repo + ", \(entries.count) pull requests")
                                    .accessibilityValue(collapsed.contains(repo) ? "Collapsed" : "Expanded")
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
                        }.padding(.horizontal, 6).padding(.vertical, 6)
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
            WorkspaceRule()
            HStack(spacing: 4) {
                Dropdown(edge: .top, options: {
                    [DropdownOption("All accounts", icon: "person.2", selected: store.scope == nil) { store.scope = nil }]
                        + store.accounts.map { account in
                            DropdownOption(account.login, icon: "person.crop.circle", selected: store.scope == account.login) {
                                store.scope = account.login
                            }
                        }
                        + [DropdownOption("Manage accounts…", icon: "person.crop.circle.badge.gearshape") { showAccounts = true }]
                }) {
                    HStack(spacing: 7) {
                        if let scope = store.scope { Avatar(login: scope, size: 20) }
                        else { Image(systemName: "person.2.fill").font(.system(size: 11)).foregroundStyle(Ink.dim).frame(width: 20) }
                        Text(store.scope ?? "All accounts").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    }
                }.fixedSize()
                Spacer()
                if store.refreshing { ProgressView().controlSize(.mini) }
                else if !store.issues.isEmpty {
                    toolIcon("exclamationmark.triangle", "GitHub sync status") { showAccounts = true }
                }
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(IconButtonStyle()).help("Settings (⌘,)").accessibilityLabel("Settings")
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 44)
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
                    FieldChrome(symbol: "magnifyingglass", height: ControlSize.large + 2) {
                        Text(store.sidebarWidth >= 230 ? "Search workspace" : "Search").foregroundStyle(Ink.dim).lineLimit(1)
                        Spacer(minLength: 4)
                        if store.sidebarWidth >= 230 { HStack(spacing: 3) { Keycap("⌘"); Keycap("K") } }
                        else { Keycap("⌘K") }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 10).headerRow(.context, rule: false)
                    .accessibilityLabel("Search workspace")
                HStack(spacing: 6) {
                    queuePicker(compact: false)
                    Text("\(store.visible.count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Ink.dim).padding(.horizontal, 6).frame(minWidth: 20, minHeight: 17)
                        .background(Color.white.opacity(0.06), in: Capsule())
                    Spacer()
                    refreshButton
                }.padding(.leading, 6).padding(.trailing, 10).headerRow(.navigation)
            }.transition(Motion.header(reduceMotion))
        }
        HStack(spacing: 4) {
            if !expanded {
                // Search stays in the sidebar when it has room; the toolbar always has it too.
                if store.sidebarWidth >= 240 { toolIcon("magnifyingglass", "Search workspace (⌘K)") { store.palette = .global } }
                queuePicker(compact: true)
            }
            FieldChrome(symbol: expanded ? "line.3.horizontal.decrease" : nil) {
                TextField(store.sidebarWidth >= (expanded ? 230 : 290) ? "Filter pull requests…" : "Filter PRs…", text: $store.query).textFieldStyle(.plain)
                    .accessibilityLabel("Filter pull requests")
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.faint) }
                        .buttonStyle(.plain).help("Clear filter").accessibilityLabel("Clear filter")
                }
            }
            if !expanded { refreshButton }
        }.padding(.horizontal, 10)
            .headerRow(code || expanded ? .controls : .navigation)
    }

    private var refreshButton: some View {
        toolIcon("arrow.clockwise", "Refresh inbox") { Task { await store.refresh() } }.disabled(store.refreshing)
    }

    private func queuePicker(compact: Bool) -> some View {
        Dropdown(options: {
            Queue.allCases.map { queue in
                DropdownOption(queue.title, icon: queue.symbol, selected: store.queue == queue) { store.queue = queue }
            }
        }) {
            if compact { Image(systemName: store.queue.symbol) }
            else { Text(store.queue == .inbox ? "Pull requests" : store.queue.title).lineLimit(1) }
        }.fixedSize()
            .font(.system(size: 13, weight: .semibold)).help(store.queue.title)
            .accessibilityLabel("Pull request queue, " + store.queue.title)
    }

    private func row(_ item: InboxItem) -> some View {
        Button { store.selection = item.id } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.pr.isDraft ? "pencil.circle" : "arrow.triangle.pull")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(item.pr.isDraft ? Ink.faint : Ink.green)
                    .frame(width: 14).padding(.top, 2)
                    .overlay {
                        if holdingCommand, let index = shortcuts.firstIndex(of: item.id) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Ink.text).frame(width: 19, height: 18).background(Ink.selection, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.dim))
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.pr.title).lineLimit(1).truncationMode(.tail).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(store.selection == item.id ? Ink.text : Ink.prose)
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(item.pr.number)").font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        Text(item.account).lineLimit(1)
                        Spacer(minLength: 0)
                        if store.saved.contains(item.id) { Image(systemName: "bookmark.fill").foregroundStyle(Ink.blue) }
                    }.font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }.padding(.leading, 10).padding(.trailing, 8).padding(.vertical, store.sidebarWidth < 240 ? 6 : 7)
                .background {
                    let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    if store.selection == item.id {
                        shape.fill(Ink.selection).overlay(shape.strokeBorder(Color.white.opacity(0.07)))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }.buttonStyle(.plain).help(item.pr.title).id(item.id)
            .accessibilityLabel((item.pr.isDraft ? "Draft, " : "") + "\(item.pr.title), #\(item.pr.number), \(item.account)")
            .accessibilityAddTraits(store.selection == item.id ? .isSelected : [])
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SidebarRowFrames.self, value: [item.id: geometry.frame(in: .named("PR viewport"))])
            })
    }
}
