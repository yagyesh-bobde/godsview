import SwiftUI
import GitHubCore

struct WorkspaceToolbar: View {
    @Bindable var store: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let height: CGFloat
    @AppStorage("t3MCPEnabled") private var t3Enabled = false
    @Environment(\.openSettings) private var openSettings

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
                    t3Menu
                } else {
                    Dropdown(bordered: true, options: {
                        [DropdownOption("Comment", icon: "text.bubble", presents: true) { store.review.sheet = .comment }]
                            + aiActions
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
    }

    private var t3Status: T3Status { T3Status.current(enabled: t3Enabled) }

    /// Always visible, so people can find T3. Until it is set up, it opens Settings and
    /// carries a small "Set up" badge instead of the menu.
    @ViewBuilder private var t3Menu: some View {
        if t3Status == .ready {
            let open = store.review.t3Visible && store.review.tab == .code
            Button { if open { store.review.t3Visible = false } else { store.review.openT3() } } label: {
                Label("Ask T3", systemImage: "sparkles")
            }
            .buttonStyle(ActionButtonStyle(kind: open ? .accent(Ink.purple) : .secondary)).fixedSize()
            .help(open ? "Hide the T3 panel" : "Ask T3 about this pull request")
            .accessibilityValue(open ? "Panel shown" : "Panel hidden")
        } else {
            Button { openSettings() } label: {
                HStack(spacing: 6) {
                    Label("Ask T3", systemImage: "sparkles")
                    Text("Set up").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.amber)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(Ink.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .buttonStyle(ActionButtonStyle(kind: .secondary)).fixedSize()
            .help(t3Status == .notInstalled ? "Install T3 Code’s t3 command, then turn it on in Settings"
                  : "Turn on T3 in Settings to ask questions and start reviews")
            .accessibilityLabel("Ask T3, set up in Settings")
        }
    }

    private var aiActions: [DropdownOption] {
        guard t3Status == .ready else {
            return [DropdownOption("Set up T3…", icon: "sparkles") { openSettings() }]
        }
        return [
            DropdownOption("Ask T3", icon: "sparkles") { store.review.openT3() },
            DropdownOption("Start T3 review", icon: "text.magnifyingglass") { store.review.openT3(.review) }
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
