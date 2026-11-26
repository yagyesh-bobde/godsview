import SwiftUI
import GitHubCore

struct WorkspaceToolbar: View {
    @Bindable var store: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        HStack(spacing: 6) {
            if store.selected != nil && store.review.tab != .discussion {
                if !compact {
                    Button { store.review.sheet = .comment } label: { Label("Comment", systemImage: "text.bubble") }
                        .buttonStyle(ActionButtonStyle(kind: .secondary)).fixedSize()
                        .help("Comment on this pull request")
                    if t3Enabled { t3Menu }
                } else if !t3Enabled {
                    // One action needs no menu; the title gets the width instead.
                    toolIcon("text.bubble", "Comment on this pull request") { store.review.sheet = .comment }
                } else {
                    Dropdown(bordered: true, options: {
                        [DropdownOption("Comment", icon: "text.bubble", presents: true) { store.review.sheet = .comment }]
                            + (t3Enabled ? aiActions : [])
                    }) { Text("Actions").font(.system(size: 12.5, weight: .semibold)) }.fixedSize()
                }
                WorkspaceRule(vertical: true).frame(height: 16).padding(.horizontal, 4)
            }
            toolIcon("magnifyingglass", "Search workspace (⌘K)") { store.palette = .global }
            if let item = store.selected {
                toolIcon(store.saved.contains(item.id) ? "bookmark.fill" : "bookmark", "Toggle saved pull request") { store.toggleSaved(item) }
                Link(destination: item.pr.url) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(IconButtonStyle()).help("Open on GitHub").accessibilityLabel("Open on GitHub")
                if !store.focusingFile && store.review.tab == .code {
                    WorkspaceRule(vertical: true).frame(height: 16).padding(.horizontal, 4)
                    toolIcon(store.review.headerCollapsed ? "chevron.down" : "chevron.up",
                             store.review.headerCollapsed ? "Expand PR header" : "Collapse PR header") {
                        store.review.automaticallyFoldHeader = false
                        store.review.headerCollapsed.toggle()
                    }
                }
            }
        }.font(.system(size: 13))
    }

    private var navigation: some View {
        let sidebarShown = store.sidebarVisible && !store.focusingFile
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { store.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle(active: false))
                    .disabled(store.focusingFile).help("Toggle PR sidebar (⌘B)").accessibilityLabel("Toggle PR sidebar")
                HStack(spacing: 0) {
                    Text("Gods").fontWeight(.semibold)
                    Text("View").foregroundStyle(Ink.dim)
                }.font(.system(size: sidebarShown && store.sidebarWidth < 215 ? 13 : 14)).tracking(-0.2).fixedSize().allowsHitTesting(false)
            }
            // Leave room for the standard close, minimize and zoom buttons.
            .padding(.leading, 84)
            .frame(width: sidebarShown ? store.sidebarWidth : nil, alignment: .leading)
            .overlay(alignment: .trailing) {
                if sidebarShown { WorkspaceRule(vertical: true).frame(height: height - 12) }
            }
            if let item = store.selected {
                contextMenu(item).padding(.leading, 12)
            }
        }.foregroundStyle(Ink.text)
            .animation(Motion.layout(reduceMotion), value: sidebarShown)
    }

    private var t3Menu: some View {
        Dropdown(bordered: true, options: { aiActions }) {
            Label("Ask T3", systemImage: "sparkles").font(.system(size: 12.5, weight: .semibold))
        }.fixedSize()
    }

    private var aiActions: [DropdownOption] {
        [
            DropdownOption("Ask a question", icon: "bubble.left.and.text.bubble.right", presents: true) { store.review.sheet = .ask },
            DropdownOption("Start PR review", icon: "text.magnifyingglass", presents: true) { store.review.sheet = .aiReview }
        ]
    }

    private func contextMenu(_ item: InboxItem) -> some View {
        let repo = item.pr.repository.nameWithOwner
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let initials = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first)
        return HStack(spacing: 7) {
            Text(String(initials).uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(Ink.green).padding(.horizontal, 4).frame(minWidth: 22, minHeight: 22)
                .background(Ink.green.opacity(0.13), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Ink.green.opacity(0.22)))
                .accessibilityHidden(true)
            Text(name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.dim)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading).fixedSize(horizontal: true, vertical: false).help(repo)
            Text("/").font(.system(size: 13.5)).foregroundStyle(Ink.faint.opacity(0.65))
            Dropdown(width: 380, options: {
                store.scoped.filter { $0.pr.repository.nameWithOwner == repo }.map { candidate in
                    DropdownOption("#\(candidate.pr.number)  \(candidate.pr.title)", icon: "arrow.triangle.pull",
                                   id: candidate.id, selected: candidate.id == item.id) {
                        if store.visible.contains(where: { $0.id == candidate.id }) { store.selection = candidate.id }
                        else { store.open(candidate) }
                    }
                }
            }) {
                Text(item.pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .help("\(repo) #\(item.pr.number) · \(item.pr.title)")
            .accessibilityLabel("Choose pull request, \(item.pr.title)")
        }
    }
}
