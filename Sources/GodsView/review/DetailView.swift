import SwiftUI
import GitHubCore

struct DetailView: View {
    let item: InboxItem
    let store: Workspace
    @State private var reload = 0
    @State private var posted = false
    @State private var metadataWidths: [Int: CGFloat] = [:]
    @State private var metadataAvailable: CGFloat = .infinity

    private var pr: PullRequest { item.pr }
    let toggleFullScreen: () -> Void
    var review: ReviewSession { store.review }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabIndicator

    var body: some View {
        @Bindable var review = store.review
        VStack(alignment: .leading, spacing: 0) {
            if !store.focusingFile {
                // The header stays mounted while folded. Rebuilding its rows each time the
                // diff scrolls back to the top stalled scrolling for a third of a second.
                VStack(spacing: 0) {
                    if review.tab == .code { codeMetadata.transition(Motion.header(reduceMotion)) }
                    tabBar
                }.foldAway(review.headerCollapsed && review.tab == .code)
                    .modifier(ReviewHeaderSlide(review: review, fades: true))
            }
            if review.tab == .code || store.focusingFile {
                CodeReviewView(item: item, store: store, toggleFullScreen: toggleFullScreen)
                    .modifier(ReviewHeaderSlide(review: review))
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // The scroll view keeps its identity; only its page cross-fades.
                        if review.tab == .summary { overview.transition(.opacity) }
                        else { DiscussionView(item: item, store: store, reload: reload).transition(.opacity) }
                    }.frame(maxWidth: 744, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        // Keyed on state, so the toolbar button, ⌘ shortcuts and the diff scrolling past
        // its fold point all animate the same way. Focus mode is left out on purpose: the
        // window itself is changing size then, and it should not race a SwiftUI animation.
        .animation(Motion.layout(reduceMotion), value: review.headerCollapsed)
        .animation(Motion.swap(reduceMotion), value: review.tab)
        .background(Ink.detail)
        .task(id: "\(item.pr.diffRevision)/\(review.retry)") { await review.loadCommits(item, client: store.client) }
        .task(id: "\(item.pr.diffRevision)/\(review.commit ?? "all")/\(review.retry)") { await review.loadFiles(item, client: store.client) }
        .sheet(item: $review.fileComment) { target in
            CommentSheet(item: item, client: store.client, target: target) { posted = true }
        }
        .sheet(item: $review.sheet) { sheet in
            switch sheet {
            case .comment:
                CommentSheet(item: item, client: store.client) {
                    review.tab = .discussion
                    reload += 1
                    posted = true
                }
            case .close, .merge:
                PullRequestActionSheet(action: sheet == .merge ? .merge : .close, item: item, store: store)
            }
        }
        .overlay(alignment: .bottom) {
            if posted { Label("Comment posted", systemImage: "checkmark.circle.fill")
                .padding(8).background(.regularMaterial, in: Capsule()).padding()
                .task { try? await Task.sleep(for: .seconds(3)); posted = false } }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(ReviewTab.allCases, id: \.self) { tab in
                ReviewTabButton(tab: tab, count: tab == .code ? pr.changedFiles : nil, selected: review.tab == tab,
                                indicator: tabIndicator) { review.tab = tab }
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if review.tab != .code {
                ViewThatFits(in: .horizontal) {
                    ReviewDecisionButtons(item: item, review: review, decisionDisplay: .full)
                    ReviewDecisionButtons(item: item, review: review, decisionDisplay: .short)
                }
            }
        }.padding(.horizontal, 12)
            .headerRow(.navigation)
    }

    /// Details yield in a deliberate order as the pane narrows: first the review badge
    /// shortens, then the source branch shortens while keeping the author's full name and
    /// target branch readable, and only at very narrow widths does the author collapse to an
    /// avatar. The 30-point actions always stay stable.
    private static let metadataVariants: [(author: AuthorDisplay, branchWidth: CGFloat?, decision: ReviewDecisionDisplay)] = [
        (.full, nil, .full), (.full, nil, .short), (.full, 155, .short), (.full, 120, .short),
        (.full, 92, .short), (.full, 68, .short), (.avatar, 100, .short), (.avatar, 68, .short),
        (.hidden, 56, .icon),
    ]

    /// Picks the first variant that fits, like `ViewThatFits`, but from widths measured once by
    /// hidden copies that stay mounted. `ViewThatFits` rebuilt every variant on each layout
    /// pass, so folding the header while scrolling stalled for half a second.
    private var codeMetadata: some View {
        let variants = Self.metadataVariants
        let chosen = variants.indices.first { (metadataWidths[$0] ?? 0) <= metadataAvailable } ?? variants.count - 1
        let variant = variants[chosen]
        return metadataRow(author: variant.author, branchWidth: variant.branchWidth, decision: variant.decision)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { metadataAvailable = $0 }
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(variants.indices, id: \.self) { index in
                        let variant = variants[index]
                        metadataRow(author: variant.author, branchWidth: variant.branchWidth, decision: variant.decision)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { metadataWidths[index] = $0 }
                    }
                }.hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .headerRow(.context, rule: false)
    }

    private func metadataRow(author: AuthorDisplay, branchWidth: CGFloat?,
                             decision: ReviewDecisionDisplay) -> some View {
        HStack(spacing: 8) {
            metadataDetails(author: author, branchWidth: branchWidth)
            Spacer(minLength: 6)
            ReviewDecisionButtons(item: item, review: review, decisionDisplay: decision)
        }
    }

    private enum AuthorDisplay { case full, avatar, hidden }

    private func metadataDetails(author: AuthorDisplay, branchWidth: CGFloat?) -> some View {
        HStack(spacing: 8) {
            StatePill(text: pr.stateLabel, color: pr.stateColor, symbol: pr.stateSymbol).fixedSize()
            Text("#\(pr.number)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
                .fixedSize()
            if author != .hidden {
                let login = pr.author?.login ?? "Deleted user"
                HStack(spacing: 5) {
                    Avatar(login: pr.author?.login ?? "?", size: 18)
                    if author == .full { Text(login).lineLimit(1).foregroundStyle(Ink.prose) }
                }.fixedSize().help(login).accessibilityElement(children: .ignore).accessibilityLabel("Author " + login)
            }
            MetaChip(filled: false) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                Text(pr.headRefName).lineLimit(1).truncationMode(.middle).foregroundStyle(Ink.prose)
                    .frame(maxWidth: branchWidth)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.faint)
                Text(pr.baseRefName).lineLimit(1).foregroundStyle(Ink.prose).fixedSize()
            }.font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .help("\(pr.headRefName) → \(pr.baseRefName)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Branch \(pr.headRefName) into \(pr.baseRefName)")
        }.font(.system(size: 12.5)).foregroundStyle(Ink.dim)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                StatePill(text: pr.stateLabel, color: pr.stateColor, symbol: pr.stateSymbol)
                Text(pr.repository.nameWithOwner).lineLimit(1).truncationMode(.middle)
                Text("#\(pr.number)").font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
            }.font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            Text(pr.title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.35)
                .lineSpacing(2)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Avatar(login: pr.author?.login ?? "?", size: 22)
                    Text(pr.author?.login ?? "Deleted user").fontWeight(.semibold).foregroundStyle(Ink.text)
                    Text("· Updated " + pr.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Ink.dim)
                }
                MetaChip(filled: false) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    Text(pr.headRefName).lineLimit(1).truncationMode(.middle).foregroundStyle(Ink.prose)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.faint)
                    Text(pr.baseRefName).lineLimit(1).foregroundStyle(Ink.prose)
                }.font(.system(size: 11.5, weight: .medium, design: .monospaced)).textSelection(.enabled)
            }.font(.callout)
            ChangedFilesCard(count: pr.changedFiles, additions: pr.additions, deletions: pr.deletions) {
                review.tab = .code
            }
            if !pr.labels.nodes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pr.labels.nodes, id: \.name) { label in
                        MetaChip(tint: Ink.purple) { Image(systemName: "tag").font(.system(size: 9.5, weight: .semibold)); Text(label.name) }
                    }
                }
            }
            LinkedIssuesView(pr: pr)
            WorkspaceRule()
            VStack(alignment: .leading, spacing: 12) {
                Text("Description").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                if (pr.body ?? pr.bodyText).isEmpty {
                    Text("No description provided.").font(.callout).foregroundStyle(Ink.dim)
                } else {
                    MarkdownBody(source: pr.body ?? pr.bodyText, url: pr.url)
                }
            }
        }
    }
}

private struct ChangedFilesCard: View {
    let count: Int
    let additions: Int
    let deletions: Int
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hovered ? Ink.text : Ink.dim)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.chip + 1, style: .continuous))
                Text("\(count) changed files").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.text)
                DiffStat(additions: additions, deletions: deletions)
                Spacer()
                HStack(spacing: 4) {
                    Text("Review diff").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }.foregroundStyle(hovered ? Ink.text : Ink.dim)
            }
            .padding(.horizontal, 12).frame(height: 50)
            .background(hovered ? Color.white.opacity(0.085) : Ink.raised, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hovered ? 0.16 : 0.1)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help("Review changed files")
    }
}

private struct DiscussionView: View {
    let item: InboxItem
    let store: Workspace
    let reload: Int
    @State private var comments: [DiscussionComment]?
    @State private var error: String?
    @State private var attempts = 0

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Discussion").font(.system(size: 20, weight: .semibold)).tracking(-0.2)
                if let comments {
                    Text("\(comments.count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Ink.dim).padding(.horizontal, 7).frame(minWidth: 22, minHeight: 19)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                Spacer()
                Link(destination: item.pr.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right")
                }.buttonStyle(ActionButtonStyle(kind: .ghost, height: ControlSize.small))
                Button { store.review.sheet = .comment } label: {
                    Label("Comment", systemImage: "text.bubble")
                }.buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.small))
            }
            WorkspaceRule()
            if let error {
                HStack { Text(error).lineLimit(2).help(error); Button("Retry") { attempts += 1 } }
                    .font(.caption).foregroundStyle(Ink.dim)
            }
            if let comments {
                if comments.isEmpty { Text("No conversation comments yet.").foregroundStyle(Ink.dim).padding(.top, 4) }
                ForEach(comments) { comment in
                    let login = comment.author?.login ?? "Deleted user"
                    let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Avatar(login: login, size: 22)
                            Text(login).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                            if comment.author?.login != nil && comment.author?.login == item.pr.author?.login {
                                StatePill(text: "Author", color: Ink.dim)
                            }
                            Spacer(minLength: 6)
                            Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11.5)).foregroundStyle(Ink.faint)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.white.opacity(0.025))
                        WorkspaceRule()
                        MarkdownBody(source: comment.body ?? comment.bodyText, url: item.pr.url)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.surface, in: shape)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
                }
                if comments.count == 20 { Link("View full conversation on GitHub", destination: item.pr.url) }
            } else if error == nil { ProgressView("Loading discussion…").controlSize(.small) }
        }.task(id: "\(reload)/\(attempts)/\(item.pr.updatedAt.timeIntervalSinceReferenceDate)") {
            error = nil
            if comments == nil { comments = await store.disk?.conversation(item.id) }
            do {
                let result = try await store.client.discussion(on: item)
                guard !Task.isCancelled else { return }
                comments = result
                await store.disk?.store(result, on: item.id)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct CommentSheet: View {
    let item: InboxItem
    let client: GitHubClient
    var target: FileCommentTarget? = nil
    let onPost: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        let editorShape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a comment").font(.title2.bold())
            Text("\(item.pr.repository.nameWithOwner) #\(item.pr.number)").font(.caption.monospaced()).foregroundStyle(Ink.dim)
            if let target {
                Text(target.description).font(.callout.monospaced()).textSelection(.enabled)
                Text(String(target.commit.prefix(10))).font(.caption.monospaced()).foregroundStyle(Ink.dim)
            }
            TextEditor(text: $bodyText).font(.body).padding(8).scrollContentBackground(.hidden)
                .frame(height: 124).background(Ink.surface, in: editorShape)
                .overlay(editorShape.strokeBorder(Ink.stroke))
                .accessibilityLabel("Comment body")
            if let error { Text(error).foregroundStyle(Ink.red).font(.caption).textSelection(.enabled) }
            HStack {
                Avatar(login: item.account)
                Text(item.account).font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(posting)
                    .buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.large))
                Button(posting ? "Posting…" : "Post comment") {
                    posting = true
                    error = nil
                    Task {
                        defer { posting = false }
                        do {
                            if let target {
                                try await client.reviewComment(bodyText, path: target.path, commit: target.commit,
                                                               range: target.range, on: item)
                            } else {
                                try await client.comment(bodyText, on: item)
                            }
                            onPost()
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(posting || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(ActionButtonStyle(kind: .primary(Ink.blue), height: ControlSize.large))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(24).frame(width: 465).background(Ink.detail).preferredColorScheme(.dark).interactiveDismissDisabled(posting)
    }
}

/// A rounded tab. The selected background slides between tabs instead of blinking.
private struct ReviewTabButton: View {
    let tab: ReviewTab
    let count: Int?
    let selected: Bool
    let indicator: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    private var symbol: String {
        switch tab {
        case .summary: "list.bullet.rectangle"
        case .discussion: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? Ink.text : Ink.faint)
                Text(tab.rawValue)
                if let count {
                    Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Ink.text : Ink.dim)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 17)
                        .background(Color.white.opacity(selected ? 0.12 : 0.06), in: Capsule())
                }
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected || hovered ? Ink.text : Ink.dim)
            .padding(.horizontal, 12).frame(height: ControlSize.large)
            .background {
                if selected {
                    shape.fill(Color.white.opacity(0.07))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
                        // A short accent line keeps the active tab findable at a glance.
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1).fill(Ink.blue).frame(height: 2).padding(.horizontal, 14)
                        }
                        .matchedGeometryEffect(id: "selected tab", in: indicator)
                } else if hovered {
                    shape.fill(Color.white.opacity(0.04))
                }
            }
            .contentShape(shape)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(count.map { "\(tab.rawValue), \($0) files" } ?? tab.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
