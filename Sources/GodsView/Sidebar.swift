import SwiftUI
import GitHubCore

struct Sidebar: View {
    @Bindable var store: Workspace
    @Binding var showAccounts: Bool
    @State private var collapsed = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Ink.blue)
                Text("GodsView").font(.system(size: 13, weight: .semibold))
                Spacer()
                toolIcon("sidebar.left", "Hide sidebar (⌘B)") { store.sidebarVisible = false }
            }.padding(.horizontal, 12).frame(height: 38)
            Button { store.palette = .global } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search workspace")
                    Spacer()
                    Text("⌘ K").font(.caption.monospaced())
                }.font(.system(size: 12)).foregroundStyle(Ink.dim).padding(.horizontal, 9).frame(height: 29)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.line))
            }.buttonStyle(.plain).padding(.horizontal, 9).padding(.bottom, 12)
            HStack {
                Menu {
                    ForEach(Queue.allCases, id: \.self) { queue in
                        Button { store.queue = queue } label: { Label(queue.title, systemImage: queue.symbol) }
                    }
                } label: { HStack(spacing: 5) { Text(store.queue == .inbox ? "Pull requests" : store.queue.title); Image(systemName: "chevron.down").font(.system(size: 8)) } }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer()
                Text("\(store.visible.count)").font(.caption.monospacedDigit()).foregroundStyle(Ink.faint)
                toolIcon("arrow.clockwise", "Refresh inbox (⌘R)") { Task { await store.refresh() } }.disabled(store.refreshing)
            }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13)
            HStack {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Ink.faint)
                TextField("Filter pull requests…", text: $store.query).textFieldStyle(.plain)
                if !store.query.isEmpty { toolIcon("xmark", "Clear filter") { store.query = "" } }
            }.font(.caption).padding(.horizontal, 14).frame(height: 28)
            Divider()
            let groups = Dictionary(grouping: store.visible) { $0.pr.repository.nameWithOwner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
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
                            if !collapsed.contains(repo) {
                                ForEach(entries) { item in row(item) }
                            }
                        }
                        if store.visible.isEmpty {
                            Text(store.refreshing ? "Syncing pull requests…" : "No pull requests in this view")
                                .font(.caption).foregroundStyle(Ink.dim).padding(10)
                        }
                    }.padding(5)
                }.onChange(of: store.selection) { _, id in
                    if let item = store.selected { collapsed.remove(item.pr.repository.nameWithOwner) }
                    if let id { proxy.scrollTo(id) }
                }
            }
            Spacer(minLength: 0)
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
                else {
                    toolIcon(store.issues.isEmpty ? "gearshape" : "exclamationmark.triangle", "GitHub accounts and sync status") { showAccounts = true }
                }
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 38)
            if store.scope.map(store.limited.contains) ?? !store.limited.isEmpty {
                Text("Latest 50 per queue").font(.caption2).foregroundStyle(Ink.dim).padding(.horizontal, 12).padding(.bottom, 6)
            }
        }.background(Ink.rail)
    }

    private func row(_ item: InboxItem) -> some View {
        Button { store.selection = item.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 11)).foregroundStyle(item.pr.isDraft ? Ink.faint : Ink.green)
                    .frame(width: 13).padding(.top, 2)
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
    }
}
