import SwiftUI
import GitHubCore

struct WorkspaceToolbar: View {
    @Bindable var store: Workspace
    let height: CGFloat
    @AppStorage("t3MCPEnabled") private var t3Enabled = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                navigation
                Spacer(minLength: 8)
                actions(compact: geometry.size.width < 1120)
                    .fixedSize()
            }
            .frame(height: geometry.size.height)
            .padding(.trailing, 14)
            .background(WindowDragSurface())
        }
        .frame(height: height)
        .background(Ink.detail)
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let item = store.selected {
                if !compact {
                    Button { store.review.sheet = .comment } label: { Label("Comment", systemImage: "text.bubble").labelStyle(.titleAndIcon).fixedSize() }.fixedSize()
                    if t3Enabled { t3Menu }
                    Button("Close PR") { store.review.sheet = .close }.disabled(!item.pr.isOpen)
                    Button("Merge PR") { store.review.sheet = .merge }.disabled(item.pr.isDraft || !item.pr.isOpen)
                } else {
                    Menu("PR actions") {
                        Button("Comment…") { store.review.sheet = .comment }
                        if t3Enabled { aiActions }
                        Button("Close PR…") { store.review.sheet = .close }.disabled(!item.pr.isOpen)
                        Button("Merge PR…") { store.review.sheet = .merge }.disabled(item.pr.isDraft || !item.pr.isOpen)
                    }.fixedSize()
                }
                Divider().frame(height: 14)
            }
            toolIcon("magnifyingglass", "Search workspace (⌘K)") { store.palette = .global }
            if let item = store.selected {
                toolIcon(store.saved.contains(item.id) ? "bookmark.fill" : "bookmark", "Toggle saved pull request") { store.toggleSaved(item) }
                Link(destination: item.pr.url) { Image(systemName: "arrow.up.right.square").frame(width: 22, height: 24) }
                    .foregroundStyle(Ink.dim).help("Open on GitHub")
                if !store.focusingFile && store.review.tab == .code {
                    Divider().frame(height: 16)
                    toolIcon(store.review.headerCollapsed ? "chevron.down" : "chevron.up",
                             store.review.headerCollapsed ? "Expand PR header" : "Collapse PR header") {
                        store.review.automaticallyFoldHeader = false
                        store.review.headerCollapsed.toggle()
                    }
                }
            }
        }.font(.system(size: 13)).buttonStyle(.plain)
    }

    private var navigation: some View {
        let sidebarShown = store.sidebarVisible && !store.focusingFile
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { store.sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.left").frame(width: 24, height: 27)
                }.disabled(store.focusingFile).help("Toggle PR sidebar (⌘B)").accessibilityLabel("Toggle PR sidebar")
                HStack(spacing: 0) {
                    Text("Gods").fontWeight(.semibold)
                    Text("View").foregroundStyle(Ink.dim)
                }.font(.system(size: sidebarShown && store.sidebarWidth < 215 ? 13 : 14)).fixedSize().allowsHitTesting(false)
            }
            // Leave room for the standard close, minimize and zoom buttons.
            .padding(.leading, 88)
            .frame(width: sidebarShown ? store.sidebarWidth : nil, alignment: .leading)
            .overlay(alignment: .trailing) {
                if sidebarShown { WorkspaceRule(vertical: true).frame(height: height - 12) }
            }
            if let item = store.selected {
                contextMenu(item).padding(.leading, 12)
            }
        }.buttonStyle(.plain).foregroundStyle(Ink.text)
    }

    private var t3Menu: some View {
        Menu("Ask T3") { aiActions }.menuStyle(.borderlessButton).fixedSize()
    }

    @ViewBuilder private var aiActions: some View {
        Button("Ask a question…") { store.review.sheet = .ask }
        Button("Start PR review…") { store.review.sheet = .aiReview }
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
                .clipped().help("\(repo) #\(item.pr.number) · \(item.pr.title)")
                .accessibilityLabel("Choose pull request, \(item.pr.title)")
        }
    }
}
