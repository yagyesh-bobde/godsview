import SwiftUI
import GitHubCore

struct DetailView: View {
    let item: InboxItem
    let store: Workspace
    @State private var reload = 0
    @State private var posted = false

    private var pr: PullRequest { item.pr }
    private var decision: String? {
        switch pr.reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: nil
        }
    }

    let toggleFullScreen: () -> Void
    var review: ReviewSession { store.review }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabIndicator

    var body: some View {
        @Bindable var review = store.review
        VStack(alignment: .leading, spacing: 0) {
            if !store.focusingFile && (!review.headerCollapsed || review.tab != .code) {
                VStack(spacing: 0) {
                    if review.tab == .code { codeMetadata.transition(Motion.header(reduceMotion)) }
                    tabBar
                }.transition(Motion.header(reduceMotion))
            }
            if review.tab == .code || store.focusingFile {
                CodeReviewView(item: item, store: store, toggleFullScreen: toggleFullScreen)
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
            case .ask, .aiReview:
                T3ConversationView(item: item, reviewRequest: sheet == .aiReview)
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
            }
            Spacer(minLength: 4)
            if review.tab != .code {
                ViewThatFits(in: .horizontal) { decisionChip(short: false); decisionChip(short: true) }
                ReviewDecisionButtons(item: item, review: review)
            }
        }.padding(.horizontal, 12)
            .headerRow(.navigation)
    }

    private var decisionStyle: (color: Color, symbol: String)? {
        switch pr.reviewDecision {
        case "APPROVED": (Ink.green, "checkmark.circle.fill")
        case "CHANGES_REQUESTED": (Ink.red, "exclamationmark.circle.fill")
        case "REVIEW_REQUIRED": (Ink.amber, "eye")
        default: nil
        }
    }

    private var codeMetadata: some View {
        HStack(spacing: 10) {
            // Drop the least important details first when the pane is narrow.
            // The author yields first; then the source branch truncates. The target stays.
            // The author becomes an avatar (name in its tooltip) before the source branch
            // shortens much. The target branch always stays readable.
            ViewThatFits(in: .horizontal) {
                metadataDetails(author: .full, branchWidth: nil)
                metadataDetails(author: .avatar, branchWidth: nil)
                metadataDetails(author: .avatar, branchWidth: 150)
                metadataDetails(author: .avatar, branchWidth: 100)
                metadataDetails(author: .avatar, branchWidth: 60)
                metadataDetails(author: .hidden, branchWidth: 60)
            }
            Spacer(minLength: 8)
            // The review state sits beside the actions it gates.
            ViewThatFits(in: .horizontal) {
                decisionChip(short: false)
                decisionChip(short: true)
            }.fixedSize(horizontal: false, vertical: true)
            ReviewDecisionButtons(item: item, review: review)
        }.padding(.horizontal, 16)
            .headerRow(.context, rule: false)
    }

    @ViewBuilder private func decisionChip(short: Bool) -> some View {
        if let decision, let style = decisionStyle {
            MetaChip(tint: style.color) {
                Image(systemName: style.symbol).font(.system(size: 10, weight: .semibold))
                if !short { Text(decision) }
            }.fixedSize().help(decision).accessibilityLabel(decision)
        }
    }

    private enum AuthorDisplay { case full, avatar, hidden }

    private func metadataDetails(author: AuthorDisplay, branchWidth: CGFloat?) -> some View {
        HStack(spacing: 10) {
            StatePill(text: pr.stateLabel, color: pr.stateColor, symbol: pr.stateSymbol).fixedSize()
            Text("#\(pr.number)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
                .fixedSize()
            if author != .hidden {
                let login = pr.author?.login ?? "Deleted user"
                HStack(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 8) {
                StatePill(text: pr.stateLabel, color: pr.stateColor, symbol: pr.stateSymbol)
                Text(pr.repository.nameWithOwner).lineLimit(1).truncationMode(.middle)
                Text("#\(pr.number)").font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
            }.font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            Text(pr.title).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Avatar(login: pr.author?.login ?? "?", size: 22)
                    Text(pr.author?.login ?? "Deleted user").fontWeight(.semibold)
                    Text("· Updated " + pr.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Ink.dim)
                }
                MetaChip(filled: false) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    Text(pr.headRefName).lineLimit(1).truncationMode(.middle).foregroundStyle(Ink.prose)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.faint)
                    Text(pr.baseRefName).lineLimit(1).foregroundStyle(Ink.prose)
                }.font(.system(size: 11.5, weight: .medium, design: .monospaced)).textSelection(.enabled)
            }.font(.callout)
            Button { review.tab = .code } label: {
                HStack(spacing: 10) {
                    Label("\(pr.changedFiles) changed files", systemImage: "doc.on.doc")
                    DiffStat(additions: pr.additions, deletions: pr.deletions)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Ink.dim)
                }.font(.callout.weight(.medium)).padding(.horizontal, 14).frame(height: 46).contentShape(Rectangle())
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.stroke))
            }.buttonStyle(.plain).help("Review changed files")
            if !pr.labels.nodes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pr.labels.nodes, id: \.name) { label in
                        MetaChip(tint: Ink.purple) { Image(systemName: "tag").font(.system(size: 9.5, weight: .semibold)); Text(label.name) }
                    }
                }
            }
            LinkedIssuesView(pr: pr)
            Rectangle().fill(Ink.line).frame(height: 1)
            Text("Description").font(.system(size: 18, weight: .semibold))
            if (pr.body ?? pr.bodyText).isEmpty {
                Text("No description provided.").font(.callout).foregroundStyle(Ink.dim)
            } else {
                MarkdownBody(source: pr.body ?? pr.bodyText, url: pr.url)
            }
        }
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
        LazyVStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Discussion").font(.title2.bold())
                if let comments { Text("\(comments.count)").font(.caption.monospacedDigit()).foregroundStyle(Ink.dim) }
                Spacer()
                Link("Open on GitHub ↗", destination: item.pr.url).font(.caption)
            }
            Rectangle().fill(Ink.line).frame(height: 1)
            if let error {
                HStack { Text(error).lineLimit(2).help(error); Button("Retry") { attempts += 1 } }
                    .font(.caption).foregroundStyle(Ink.dim)
            }
            if let comments {
                if comments.isEmpty { Text("No conversation comments yet.").foregroundStyle(Ink.dim) }
                ForEach(comments) { comment in
                    HStack(alignment: .top, spacing: 12) {
                        let login = comment.author?.login ?? "Deleted user"
                        VStack(spacing: 7) {
                            Avatar(login: login, size: 29)
                            Rectangle().fill(Ink.line).frame(width: 1)
                        }.frame(width: 29)
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Text(login).font(.callout.weight(.semibold))
                                if comment.author?.login != nil && comment.author?.login == item.pr.author?.login {
                                    StatePill(text: "Author", color: Ink.dim)
                                }
                                Spacer(minLength: 3)
                                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Ink.dim)
                            }.frame(minHeight: 29)
                            MarkdownBody(source: comment.body ?? comment.bodyText, url: item.pr.url)
                                .padding(.bottom, 10)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
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
        VStack(alignment: .leading, spacing: 13) {
            Text("Add a comment").font(.title2.bold())
            Text("\(item.pr.repository.nameWithOwner) #\(item.pr.number)").foregroundStyle(Ink.dim)
            if let target {
                Text(target.description).font(.callout.monospaced()).textSelection(.enabled)
                Text(String(target.commit.prefix(10))).font(.caption.monospaced()).foregroundStyle(Ink.dim)
            }
            TextEditor(text: $bodyText).font(.body).padding(6).scrollContentBackground(.hidden)
                .frame(height: 120).background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Comment body")
            if let error { Text(error).foregroundStyle(Ink.blue).font(.caption).textSelection(.enabled) }
            HStack {
                Avatar(login: item.account)
                Text(item.account).font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(posting)
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
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(22).frame(width: 465).background(Ink.detail).preferredColorScheme(.dark).interactiveDismissDisabled(posting)
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
                    .foregroundStyle(selected ? Ink.blue : Ink.faint)
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
                    shape.fill(Ink.raised).overlay(shape.strokeBorder(Ink.stroke))
                        // A short accent line keeps the active tab findable at a glance.
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1).fill(Ink.blue).frame(height: 2).padding(.horizontal, 12)
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
