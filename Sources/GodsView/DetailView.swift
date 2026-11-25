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

    var body: some View {
        @Bindable var review = store.review
        VStack(alignment: .leading, spacing: 0) {
            if !store.focusingFile && !review.headerCollapsed {
                if review.tab == .code { codeMetadata }
                HStack(spacing: 16) {
                    ForEach(ReviewTab.allCases, id: \.self) { tab in
                        Button { review.tab = tab } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab == .code ? "chevron.left.forwardslash.chevron.right" : (tab == .discussion ? "bubble.left.and.bubble.right" : "list.bullet.rectangle"))
                                Text(tab.rawValue)
                                if tab == .code { Text("\(pr.changedFiles)").foregroundStyle(Ink.dim).font(.caption2.monospacedDigit()) }
                            }.padding(.vertical, 9).foregroundStyle(review.tab == tab ? Ink.text : Ink.dim)
                                .overlay(alignment: .bottom) { if review.tab == tab { Rectangle().fill(Ink.blue).frame(height: 2) } }
                        }.buttonStyle(.plain)
                    }
                    Spacer()

                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 16)
                Divider()
            }
            if review.tab == .code || store.focusingFile {
                CodeReviewView(item: item, store: store, toggleFullScreen: toggleFullScreen)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if review.tab == .summary { overview }
                        else { DiscussionView(item: item, store: store, reload: reload) }
                    }.frame(maxWidth: 744, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Ink.detail)
        .task(id: "\(item.pr.diffRevision)/\(review.retry)") { await review.loadCommits(item, client: store.client) }
        .task(id: "\(item.pr.diffRevision)/\(review.commit ?? "all")/\(review.retry)") { await review.loadFiles(item, client: store.client) }
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

    private var codeMetadata: some View {
        HStack(spacing: 9) {
            StatePill(text: pr.isDraft ? "Draft" : "Open", color: pr.isDraft ? Ink.dim : Ink.green)
            Text("#\(pr.number)").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Ink.text)
            Text(pr.author?.login ?? "Deleted user").lineLimit(1)
            Divider().frame(height: 13)
            Image(systemName: "arrow.triangle.branch")
            Text("\(pr.headRefName) → \(pr.baseRefName)").font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            if let decision { Text("·"); Text(decision).fixedSize() }
            Spacer(minLength: 2)
        }.font(.system(size: 12)).foregroundStyle(Ink.dim).padding(.horizontal, 16).padding(.top, 11).padding(.bottom, 4)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 8) {
                StatePill(text: pr.isDraft ? "Draft" : "Open", color: pr.isDraft ? Ink.dim : Ink.green)
                Text(pr.repository.nameWithOwner).lineLimit(1).truncationMode(.middle)
                Text("#\(pr.number)").font(.caption.monospaced())
                if let decision { Spacer(); Text(decision).lineLimit(1) }
            }.font(.caption).foregroundStyle(Ink.dim)
            Text(pr.title).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Avatar(login: pr.author?.login ?? "?", size: 22)
                    Text(pr.author?.login ?? "Deleted user").fontWeight(.semibold)
                    Text("· Updated " + pr.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Ink.dim)
                }
                Label("\(pr.headRefName) → \(pr.baseRefName)", systemImage: "arrow.triangle.branch")
                    .font(.caption.monospaced()).foregroundStyle(Ink.dim).textSelection(.enabled)
            }.font(.callout)
            Button { review.tab = .code } label: {
                HStack(spacing: 10) {
                    Label("\(pr.changedFiles) changed files", systemImage: "doc.on.doc")
                    DiffStat(additions: pr.additions, deletions: pr.deletions)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Ink.dim)
                }.font(.callout.weight(.medium)).padding(12).contentShape(Rectangle())
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.line))
            }.buttonStyle(.plain).help("Review changed files")
            if !pr.labels.nodes.isEmpty {
                Text(pr.labels.nodes.map(\.name).joined(separator: "   ·   ")).font(.caption).foregroundStyle(Ink.purple)
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
    let onPost: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Add a comment").font(.title2.bold())
            Text("\(item.pr.repository.nameWithOwner) #\(item.pr.number)").foregroundStyle(Ink.dim)
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
                        do { try await client.comment(bodyText, on: item); onPost(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(posting || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(22).frame(width: 465).background(Ink.detail).preferredColorScheme(.dark).interactiveDismissDisabled(posting)
    }
}
