import SwiftUI
import GitHubCore

struct DetailView: View {
    let item: InboxItem
    let store: Workspace
    @State private var composing = false
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
        VStack(alignment: .leading, spacing: 0) {
            if !store.focusingFile && !review.headerCollapsed {
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
                    Button { composing = true } label: { Label("Comment", systemImage: "text.bubble") }
                        .buttonStyle(.plain).foregroundStyle(Ink.dim).help("Comment as " + item.account)
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 16)
                Divider()
            }
            if review.tab == .code || store.focusingFile {
                CodeReviewView(item: item, store: store, toggleFullScreen: toggleFullScreen)
            } else {
                ScrollView {
                    if review.tab == .summary { overview.padding(20) }
                    else { DiscussionView(item: item, client: store.client, reload: reload).padding(20) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Ink.detail)
        .task(id: "\(item.pr.diffRevision)/\(review.retry)") { await review.loadCommits(item, client: store.client) }
        .task(id: "\(item.pr.diffRevision)/\(review.commit ?? "all")/\(review.retry)") { await review.loadFiles(item, client: store.client) }
        .sheet(isPresented: $composing) {
            CommentSheet(item: item, client: store.client) {
                review.tab = .discussion
                reload += 1
                posted = true
            }
        }
        .overlay(alignment: .bottom) {
            if posted { Label("Comment posted", systemImage: "checkmark.circle.fill")
                .padding(8).background(.regularMaterial, in: Capsule()).padding()
                .task { try? await Task.sleep(for: .seconds(3)); posted = false } }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow { Text("Author"); Text(pr.author?.login ?? "Deleted user").foregroundStyle(Ink.text) }
                GridRow { Text("Branches"); Text("\(pr.headRefName) → \(pr.baseRefName)").font(.caption.monospaced()).textSelection(.enabled) }
                GridRow { Text("Updated"); Text(pr.updatedAt.formatted(date: .abbreviated, time: .shortened)) }
            }.font(.system(size: 12)).foregroundStyle(Ink.dim)
            HStack {
                Image(systemName: "doc.on.doc")
                Text("\(pr.changedFiles) \(pr.changedFiles == 1 ? "file" : "files") changed")
                Spacer()
                Text("+\(pr.additions)").foregroundStyle(Ink.green)
                Text("−\(pr.deletions)").foregroundStyle(.pink)
            }.font(.caption.monospacedDigit()).foregroundStyle(Ink.dim)
                .padding(10).background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
            if !pr.labels.nodes.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SectionCaption("Labels")
                    Text(pr.labels.nodes.map(\.name).joined(separator: "  ·  ")).font(.caption).foregroundStyle(Ink.purple)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                SectionCaption("Description")
                Text(pr.bodyText.isEmpty ? "No description provided." : pr.bodyText)
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(pr.bodyText.isEmpty ? Ink.faint : Ink.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DiscussionView: View {
    let item: InboxItem
    let client: GitHubClient
    let reload: Int
    @State private var comments: [DiscussionComment]?
    @State private var error: String?
    @State private var attempts = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionCaption("Recent conversation")
            if let error {
                Text(error).font(.caption).textSelection(.enabled)
                Button("Retry") { attempts += 1 }
            } else if let comments {
                if comments.isEmpty { Text("No conversation comments yet.").foregroundStyle(Ink.dim) }
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(comment.author?.login ?? "Deleted user").bold()
                            Spacer()
                            Text(comment.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(Ink.dim)
                        }.font(.caption)
                        Text(comment.bodyText).textSelection(.enabled)
                    }
                    Divider()
                }
                if comments.count == 20 { Link("View full conversation on GitHub", destination: item.pr.url) }
            } else {
                ProgressView().controlSize(.small)
            }
        }.task(id: "\(reload)/\(attempts)/\(item.pr.updatedAt)") {
            error = nil
            do {
                let result = try await client.discussion(on: item)
                if !Task.isCancelled { comments = result }
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
        }.padding(22).frame(width: 465).interactiveDismissDisabled(posting)
    }
}
