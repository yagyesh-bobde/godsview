import SwiftUI
import GitHubCore

struct CodeReviewView: View {
    let item: InboxItem
    @Bindable var store: Workspace
    var review: ReviewSession { store.review }
    let toggleFullScreen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { store.palette = .commits } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        Text(review.selectedCommit?.messageHeadline ?? "All commits").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.padding(.horizontal, 8).frame(height: 23).background(Ink.surface, in: RoundedRectangle(cornerRadius: 5))
                }.help("Choose a commit (⇧⌘O)")
                if let commit = review.selectedCommit {
                    Text(commit.shortID).font(.caption.monospaced()).foregroundStyle(Ink.dim)
                }
                ForEach([-1, 1], id: \.self) { direction in
                    Button {
                        if let next = review.adjacentCommit(direction) { review.selectCommit(next.oid) }
                    } label: { Image(systemName: direction < 0 ? "chevron.left" : "chevron.right") }
                        .disabled(review.adjacentCommit(direction) == nil)
                        .help(direction < 0 ? "Previous commit (⌥⌘←)" : "Next commit (⌥⌘→)")
                }
                Spacer()
                if !review.filesLoading {
                    Text(review.commit == nil && review.files.count < item.pr.changedFiles
                         ? "\(review.files.count) of \(item.pr.changedFiles) files" : "\(review.files.count) files").foregroundStyle(Ink.dim)
                    DiffStat(additions: review.files.reduce(0) { $0 + $1.additions }, deletions: review.files.reduce(0) { $0 + $1.deletions })
                }
                Divider().frame(height: 14)
                toolIcon("list.bullet.indent", "Toggle file tree") { store.toggleTree() }
                toolIcon(store.focusingFile ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         store.focusingFile ? "Exit full-screen file view" : "Full-screen file view (⇧⌘Return)", action: toggleFullScreen)
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 12).frame(height: 38)
            Divider()
            HSplitView {
                editor.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                if store.treeVisible {
                    FileTreeView(review: review) { store.palette = .files }
                        .frame(minWidth: 170, idealWidth: 235, maxWidth: 275, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if review.filesLoading {
            ProgressView("Loading changes…").controlSize(.small)
        } else if let error = review.filesError {
            ReviewError(message: error) { review.retry += 1 }
        } else if let file = review.selectedFile {
            FileEditor(file: file, item: item, review: review, client: store.client).id(file.sha + "/" + file.id)
        } else {
            ContentUnavailableView("No changed files", systemImage: "doc.on.doc")
        }
    }
}

private struct FileTreeView: View {
    @Bindable var review: ReviewSession
    let openSearch: () -> Void
    @State private var collapsed = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed files").font(.system(size: 12, weight: .semibold))
                Spacer()
                toolIcon("magnifyingglass", "Quick open file (⌘P)", action: openSearch)
            }.padding(.horizontal, 12).frame(height: 36)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Ink.faint)
                TextField("Filter files…", text: $review.filter).textFieldStyle(.plain).accessibilityLabel("Filter file paths")
            }.font(.system(size: 11)).padding(.horizontal, 7).frame(height: 25)
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 4)).padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            let rows = FileTreeRow.rows(files: review.files, filter: review.filter, collapsed: collapsed)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            Button {
                                if row.file != nil { review.path = row.path }
                                else if !collapsed.insert(row.path).inserted { collapsed.remove(row.path) }
                            } label: {
                                HStack(spacing: 5) {
                                    if let file = row.file {
                                        Image(systemName: "doc.text").foregroundStyle(Ink.faint)
                                        Text(row.name).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 2)
                                        Text(statusLetter(file.status)).font(.caption.monospaced())
                                            .foregroundStyle(file.status == "removed" ? Ink.red : (file.status == "added" ? Ink.green : Ink.blue))
                                    } else {
                                        Image(systemName: collapsed.contains(row.path) && review.filter.isEmpty ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 8)).frame(width: 9)
                                        Image(systemName: "folder").foregroundStyle(Ink.faint)
                                        Text(row.name).lineLimit(1)
                                        Spacer(minLength: 1)
                                    }
                                }.font(.system(size: 11)).padding(.leading, CGFloat(7 + row.depth * 11)).padding(.trailing, 8)
                                    .frame(height: 24).background(row.file != nil && review.path == row.path ? Ink.selection : .clear,
                                                                in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(row.path).id(row.id)
                        }
                        if rows.isEmpty && !review.filter.isEmpty { Text("No matching paths").font(.caption).foregroundStyle(Ink.dim).padding(8) }
                    }.padding(5)
                }.onChange(of: review.path) { _, path in
                    guard let path else { return }
                    collapsed = collapsed.filter { !path.hasPrefix($0 + "/") }
                    proxy.scrollTo("file/" + path)
                }
            }
            Spacer(minLength: 0)
        }.background(Ink.rail)
    }

    private func statusLetter(_ status: String) -> String {
        switch status { case "added": "A"; case "removed": "D"; case "renamed": "R"; default: "M" }
    }
}

private struct FileEditor: View {
    let file: ChangedFile
    let item: InboxItem
    @Bindable var review: ReviewSession
    let client: GitHubClient
    @State private var source: String?
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(Ink.faint)
                Text(file.filename).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .help(file.previousFilename.map { "\($0) → \(file.filename)" } ?? file.filename)
                Spacer(minLength: 3)
                DiffStat(additions: file.additions, deletions: file.deletions)
                Picker("View", selection: $review.mode) {
                    ForEach(FileMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).controlSize(.mini).frame(width: 78)
                toolIcon("magnifyingglass", "Find in file (⌘F)") { NotificationCenter.default.post(name: .findReviewText, object: nil) }
            }.padding(.horizontal, 10).frame(height: 35).background(Ink.rail)
            Divider()
            Group {
                if review.mode == .diff {
                    if let patch = file.patch, !patch.isEmpty {
                        CodeTextView(text: patch, path: file.filename, mode: .diff, identity: "\(item.id)/\(review.commit ?? "all")/\(file.id)/\(file.sha)/\(item.pr.updatedAt)")
                    } else {
                        VStack(spacing: 10) {
                            Text(file.status == "renamed" ? "File renamed" : "No text patch supplied by GitHub")
                            if let previous = file.previousFilename { Text(previous + " → " + file.filename).font(.caption) }
                            Button("View full file") { review.mode = .source }
                        }
                    }
                } else if let failure { ReviewError(message: failure) { retry += 1 } }
                else if let source {
                    if source.isEmpty { Text("Empty file").foregroundStyle(Ink.dim) }
                    else { CodeTextView(text: source, path: file.filename, mode: .source, identity: "blob/" + file.sha) }
                } else { ProgressView("Loading file…").controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.task(id: "\(review.mode)/\(file.sha)/\(retry)") {
            source = nil
            failure = nil
            guard review.mode == .source else { return }
            do {
                let result = try await client.source(of: file, on: item)
                if !Task.isCancelled { source = result }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct ReviewError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text(message).font(.caption).foregroundStyle(Ink.dim).textSelection(.enabled)
            Button("Retry", action: retry)
        }.padding()
    }
}

struct DiffStat: View {
    let additions: Int
    let deletions: Int
    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(Ink.green)
            Text("−\(deletions)").foregroundStyle(Ink.red)
        }.font(.system(size: 10, design: .monospaced)).fixedSize()
    }
}

@MainActor func toolIcon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 21, height: 23).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(Ink.dim).help(help).accessibilityLabel(help)
}
