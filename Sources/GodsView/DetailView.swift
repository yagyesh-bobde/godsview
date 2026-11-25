import SwiftUI
import GitHubCore

struct DetailView: View {
    let item: InboxItem
    let store: Workspace
    @State private var tab = "Overview"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionCaption("Pull request")
                Spacer()
                Button { store.toggleSaved(item) } label: {
                    Image(systemName: store.saved.contains(item.id) ? "bookmark.fill" : "bookmark")
                }.buttonStyle(.plain).foregroundStyle(store.saved.contains(item.id) ? Ink.amber : Ink.dim)
                    .help(store.saved.contains(item.id) ? "Remove from saved" : "Save pull request")
                Link(destination: pr.url) { Image(systemName: "arrow.up.right.square") }
                    .foregroundStyle(Ink.dim).help("Open on GitHub")
            }.padding(.horizontal, 22).frame(height: 45)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 7) {
                        StatePill(text: pr.isDraft ? "Draft" : "Open", color: pr.isDraft ? Ink.dim : Ink.green)
                        if let decision { StatePill(text: decision, color: decision == "Approved" ? Ink.green : Ink.amber) }
                        Spacer()
                        Text("#\(pr.number)").font(.caption.monospaced()).foregroundStyle(Ink.faint)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pr.title).font(.system(size: 23, weight: .semibold)).tracking(-0.6).textSelection(.enabled)
                        Label(pr.repository.nameWithOwner, systemImage: "shippingbox")
                            .font(.system(size: 12)).foregroundStyle(Ink.dim).textSelection(.enabled)
                    }
                    HStack(spacing: 18) {
                        ForEach(["Overview", "Discussion"], id: \.self) { name in
                            Button { tab = name } label: {
                                Text(name).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(tab == name ? Ink.amber : Ink.dim).padding(.vertical, 9)
                                    .overlay(alignment: .bottom) { if tab == name { Rectangle().fill(Ink.amber).frame(height: 2) } }
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }.overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 0.5) }
                    if tab == "Overview" {
                        overview
                    } else {
                        DiscussionView(item: item, client: store.client, reload: reload)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Avatar(login: item.account)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Acting as").font(.caption2).foregroundStyle(Ink.faint)
                    Text(item.account).font(.caption.weight(.medium)).lineLimit(1)
                }
                Spacer()
                Button { composing = true } label: {
                    Label("Comment", systemImage: "text.bubble").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 29).foregroundStyle(Ink.rail)
                        .background(Ink.amber, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 16).frame(height: 55)
        }
        .sheet(isPresented: $composing) {
            CommentSheet(item: item, client: store.client) {
                tab = "Discussion"
                reload += 1
                posted = true
            }
        }
        .overlay(alignment: .bottom) {
            if posted { Label("Comment posted", systemImage: "checkmark.circle.fill")
                .padding(8).background(.regularMaterial, in: Capsule()).padding(.bottom, 60)
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
            if let error { Text(error).foregroundStyle(Ink.amber).font(.caption).textSelection(.enabled) }
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
