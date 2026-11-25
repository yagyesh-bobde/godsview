import SwiftUI
import GitHubCore

struct InboxView: View {
    @Bindable var store: Workspace
    @Binding var showAccounts: Bool
    @FocusState private var searching: Bool

    var body: some View {
        let visible = store.visible
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "tray.2").foregroundStyle(Ink.amber)
                    Text("Workspace").foregroundStyle(Ink.dim)
                    Image(systemName: "chevron.right").font(.system(size: 8))
                    Text(store.scope ?? "All accounts").lineLimit(1)
                    Spacer()
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(store.refreshing).keyboardShortcut("r").help("Refresh (⌘R)")
                }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 22).frame(height: 45)
                Divider()
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(store.queue.title).font(.system(size: 25, weight: .semibold)).tracking(-1)
                        Text("\(visible.count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Ink.dim).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Ink.surface, in: Capsule())
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Ink.faint)
                        TextField("Filter pull requests", text: $store.query).textFieldStyle(.plain)
                            .focused($searching).accessibilityLabel("Filter pull requests")
                        if store.query.isEmpty {
                            Button("⌘F") { searching = true }.buttonStyle(.plain).keyboardShortcut("f")
                                .font(.caption.monospaced()).foregroundStyle(Ink.faint)
                        } else {
                            Button { store.query = ""; searching = true } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Ink.faint).help("Clear filter")
                        }
                    }.padding(.horizontal, 10).frame(height: 32)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searching ? Ink.amber.opacity(0.6) : Ink.line))
                }.padding(.horizontal, 20).padding(.vertical, 17)
                HStack {
                    SectionCaption("Pull requests")
                    Spacer()
                    Label("Recently updated", systemImage: "arrow.down").font(.caption).foregroundStyle(Ink.dim)
                }.padding(.horizontal, 22).padding(.vertical, 9)
                Divider()
                if visible.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $store.selection) {
                        ForEach(visible) { item in
                            InboxRow(item: item, selected: store.selection == item.id, saved: store.saved.contains(item.id))
                                .tag(item.id).listRowSeparator(.hidden)
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
                }
                Divider()
                HStack(spacing: 7) {
                    if store.refreshing {
                        ProgressView().controlSize(.mini)
                        Text("Syncing with GitHub…")
                    } else if !store.issues.isEmpty {
                        Button { showAccounts = true } label: { Label("Sync needs attention", systemImage: "exclamationmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(Ink.amber)
                    } else if let date = store.lastRefresh {
                        Circle().fill(Ink.green).frame(width: 5, height: 5)
                        Text("Synced \(date.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer()
                    if store.scope.map(store.limited.contains) ?? !store.limited.isEmpty {
                        Text("Latest 50 per queue").help("One or more queues have additional results on GitHub.")
                    }
                }.font(.caption).foregroundStyle(Ink.dim).padding(.horizontal, 18).frame(height: 29)
            }.frame(minWidth: 310, idealWidth: 425, maxWidth: .infinity).background(Ink.list)
            Group {
                if let item = visible.first(where: { $0.id == store.selection }) {
                    DetailView(item: item, store: store).id(item.id)
                } else {
                    ContentUnavailableView("Select a pull request", systemImage: "rectangle.righthalf.inset.filled")
                }
            }.frame(minWidth: 310, idealWidth: 410, maxWidth: .infinity, maxHeight: .infinity).background(Ink.detail)
        }
        .onChange(of: visible.map(\.id), initial: true) { _, ids in
            if !ids.contains(store.selection ?? "") { store.selection = ids.first }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusInboxSearch)) { _ in searching = true }
    }

    @ViewBuilder private var emptyState: some View {
        if store.refreshing {
            ProgressView("Loading pull requests…").controlSize(.small)
        } else if !store.query.isEmpty {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try another title, repository, author, or PR number."))
        } else if store.accounts.isEmpty || !store.issues.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "terminal").font(.title).foregroundStyle(Ink.amber)
                Text(store.accounts.isEmpty ? "Connect GitHub CLI" : "Check account status").font(.headline)
                Button("View connection details") { showAccounts = true }
            }
        } else {
            ContentUnavailableView(store.queue == .saved ? "No saved pull requests" : "Nothing in this queue",
                                   systemImage: store.queue.symbol,
                                   description: Text(store.queue == .saved ? "Bookmark an open pull request to keep it here." : "Open pull requests for this account filter will appear here."))
        }
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let selected: Bool
    let saved: Bool
    var body: some View {
        let pr = item.pr
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(pr.isDraft ? Ink.faint : Ink.green)
                Text(pr.repository.nameWithOwner).lineLimit(1).truncationMode(.middle)
                Text("#\(pr.number)").font(.caption.monospaced()).foregroundStyle(Ink.faint)
                Spacer(minLength: 4)
                Text(pr.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.caption2).foregroundStyle(Ink.faint)
            }.font(.caption).foregroundStyle(Ink.dim)
            Text(pr.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).foregroundStyle(Ink.text)
            HStack(spacing: 6) {
                Avatar(login: item.account, size: 16)
                Text(item.account).lineLimit(1).font(.caption).foregroundStyle(Ink.dim)
                Spacer()
                if saved { Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Ink.amber) }
                if pr.isDraft { StatePill(text: "Draft", color: Ink.dim) }
                else if item.queues.contains(.reviews) { StatePill(text: "Review requested", color: Ink.amber) }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color(red: 0.21, green: 0.185, blue: 0.153) : Ink.list)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Ink.amber).frame(width: 2) } }
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 0.5) }
            .contentShape(Rectangle())
    }
}

extension Notification.Name {
    static let focusInboxSearch = Notification.Name("focusInboxSearch")
}
