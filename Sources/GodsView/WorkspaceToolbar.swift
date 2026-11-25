import SwiftUI
import GitHubCore

struct WorkspaceToolbar: ToolbarContent {
    @Bindable var store: Workspace
    let width: CGFloat

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 13) {
                Button { store.sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.left").frame(width: 24, height: 27)
                }.disabled(store.focusingFile).help("Toggle PR sidebar (⌘B)").accessibilityLabel("Toggle PR sidebar")
                HStack(spacing: 0) {
                    Text("Gods").fontWeight(.semibold)
                    Text("View").foregroundStyle(Ink.dim)
                }.font(.system(size: 14))
                if let item = store.selected {
                    Divider().frame(height: 17)
                    contextMenu(item)
                }
            }.buttonStyle(.plain).foregroundStyle(Ink.text)
        }.flatChrome()
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                toolIcon("magnifyingglass", "Search workspace (⌘K)") { store.palette = .global }
                if let item = store.selected {
                    toolIcon(store.saved.contains(item.id) ? "bookmark.fill" : "bookmark", "Toggle saved pull request") { store.toggleSaved(item) }
                    Link(destination: item.pr.url) { Image(systemName: "arrow.up.right.square").frame(width: 22, height: 24) }
                        .foregroundStyle(Ink.dim).help("Open on GitHub")
                    if !store.focusingFile {
                        Divider().frame(height: 16)
                        toolIcon(store.review.headerCollapsed ? "chevron.down" : "chevron.up",
                                 store.review.headerCollapsed ? "Expand PR header" : "Collapse PR header") {
                            store.review.automaticallyFoldHeader = false
                            store.review.headerCollapsed.toggle()
                        }
                    }
                }
            }.font(.system(size: 13)).buttonStyle(.plain)
        }.flatChrome()
    }

    private func contextMenu(_ item: InboxItem) -> some View {
        let repo = item.pr.repository.nameWithOwner
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let initials = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first)
        return HStack(spacing: 9) {
            Text(String(initials).uppercased()).font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Ink.green).padding(.horizontal, 4).frame(minWidth: 19, minHeight: 18)
                .background(Ink.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
            Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.dim)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading).fixedSize(horizontal: true, vertical: false).help(repo)
            Text("/").foregroundStyle(Ink.faint)
            Menu {
                ForEach(store.scoped.filter { $0.pr.repository.nameWithOwner == repo }) { candidate in
                    Button {
                        if store.visible.contains(where: { $0.id == candidate.id }) { store.selection = candidate.id }
                        else { store.open(candidate) }
                    } label: {
                        if candidate.id == item.id { Label("#\(candidate.pr.number)  \(candidate.pr.title)", systemImage: "checkmark") }
                        else { Text("#\(candidate.pr.number)  \(candidate.pr.title)") }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(item.pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(Ink.dim)
                }
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(idealWidth: min(430, width - 580), maxWidth: max(160, min(640, width - 580)), alignment: .leading)
                .clipped().help("\(repo) #\(item.pr.number) · \(item.pr.title)")
                .accessibilityLabel("Choose pull request, \(item.pr.title)")
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder func flatChrome() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
        #else
        self
        #endif
    }
}
