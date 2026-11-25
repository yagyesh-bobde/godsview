import SwiftUI
import GitHubCore

struct CodeReviewView: View {
    let item: InboxItem
    @Bindable var store: Workspace
    var review: ReviewSession { store.review }
    private var viewed: ViewedFiles { review.cache.viewed(on: item) }
    let toggleFullScreen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    DiffStat(additions: review.snapshot?.additions ?? 0, deletions: review.snapshot?.deletions ?? 0)
                }
                Divider().frame(height: 14)
                if !review.singleFile && !store.focusingFile && !review.files.isEmpty {
                    let allFolded = review.collapsedFiles.count == review.files.count
                    Button(allFolded ? "Expand all" : "Collapse all") { review.toggleAllFiles() }
                        .help(allFolded ? "Expand all file diffs" : "Collapse all file diffs")
                }
                toolIcon("list.bullet.indent", "Toggle changed files sidebar (⌘L)") { store.toggleTree() }
                toolIcon(store.focusingFile ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         store.focusingFile ? "Exit full-screen file view" : "Full-screen file view (⇧⌘Return)", action: toggleFullScreen)
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 12).headerRow(.controls)
            if let error = review.filesError, review.snapshot != nil {
                HStack {
                    Text("Refresh failed. Showing cached changes.").help(error)
                    Button("Retry") { review.retry += 1 }
                }.font(.caption).padding(6)
            }
            if let error = viewed.error {
                HStack {
                    Text("Viewed files: " + error).lineLimit(2)
                    Button("Refresh") { Task { await viewed.refresh(item, client: store.client) } }
                }.font(.caption).padding(6)
            }
            editorSplit
        }.task(id: item.pr.diffRevision) { await viewed.refresh(item, client: store.client) }
    }

    private var editorSplit: some View {
        HStack(spacing: 0) {
            editor.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                // Cross-fade only when the pane changes what it shows (loading, the whole
                // diff, one file, an error). Scrolling the diff moves `review.path` all the
                // time and stepping between files should stay instant, so neither animates.
                .animation(Motion.swap(reduceMotion), value: editorPhase)
                .clipped()
            WorkspacePane(store: store, visible: store.treeVisible, trailing: true) {
                FileTreeView(review: review, viewed: viewed) { store.palette = .files }
            }
        }
    }

    private enum EditorPhase { case loading, failed, stream, file, empty }

    private var editorPhase: EditorPhase {
        if review.filesLoading { return .loading }
        if review.filesError != nil, review.snapshot == nil { return .failed }
        if let snapshot = review.snapshot, !snapshot.files.isEmpty, !review.singleFile, !store.focusingFile { return .stream }
        return review.selectedFile == nil ? .empty : .file
    }

    @ViewBuilder private var editor: some View {
        if review.filesLoading {
            ProgressView("Loading changes…").controlSize(.small).transition(.opacity)
        } else if let error = review.filesError, review.snapshot == nil {
            ReviewError(message: error) { review.retry += 1 }.transition(.opacity)
        } else if let snapshot = review.snapshot, !snapshot.files.isEmpty, !review.singleFile, !store.focusingFile {
            DiffStream(snapshot: snapshot, review: review, collapsed: review.collapsedFiles, viewed: viewed, viewedVersion: viewed.version, reveal: review.revealRequest, item: item, client: store.client)
                .transition(.opacity)
        } else if let file = review.selectedFile {
            FileEditor(file: file, item: item, review: review, client: store.client, canReturn: !store.focusingFile).id(file.sha + "/" + file.id)
                .transition(.opacity)
        } else {
            ContentUnavailableView("No changed files", systemImage: "doc.on.doc").transition(.opacity)
        }
    }
}

private struct FileTreeView: View {
    @Bindable var review: ReviewSession
    let viewed: ViewedFiles
    let openSearch: () -> Void
    @State private var collapsed = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed files").font(.system(size: 12, weight: .semibold))
                Spacer()
                toolIcon(collapsed.isEmpty ? "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left" : "arrow.up.left.and.arrow.down.right",
                         collapsed.isEmpty ? "Collapse folders" : "Expand folders") {
                    if collapsed.isEmpty { collapsed = Set((review.snapshot?.tree ?? []).filter { $0.file == nil }.map(\.path)) }
                    else { collapsed.removeAll() }
                }
                toolIcon("magnifyingglass", "Quick open file (⌘P)", action: openSearch)
            }.padding(.horizontal, 12).frame(height: 36)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Ink.faint)
                TextField("Filter files…", text: $review.filter).textFieldStyle(.plain).accessibilityLabel("Filter file paths")
            }.font(.system(size: 11)).padding(.horizontal, 7).frame(height: 25)
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 4)).padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            let rows = FileTreeRow.visible(review.snapshot?.tree ?? [], filter: review.filter, collapsed: collapsed)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            Button {
                                if row.file != nil { review.reveal(row.path) }
                                else if !collapsed.insert(row.path).inserted { collapsed.remove(row.path) }
                            } label: {
                                HStack(spacing: 5) {
                                    if let file = row.file {
                                        Image(systemName: viewed.files[file.filename] == true ? "checkmark.circle.fill" : "doc.text")
                                            .foregroundStyle(viewed.files[file.filename] == true ? Ink.green : Ink.faint)
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
    let canReturn: Bool
    @State private var source: String?
    @State private var failure: String?
    @State private var retry = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func commentForRows(_ rows: ClosedRange<Int>) -> FileCommentTarget? {
        guard let snapshot = review.snapshot, let index = snapshot.indices[file.filename] else { return nil }
        let lines = snapshot.lines[index]
        let range: ReviewLineRange?
        if review.mode == .diff {
            guard lines.indices.contains(rows.lowerBound), lines.indices.contains(rows.upperBound) else { return nil }
            range = PatchLine.commentRange(lines[rows])
        } else {
            let left = file.status == "removed"
            let first = rows.lowerBound + 1, last = rows.upperBound + 1
            guard let start = lines.firstIndex(where: { (left ? $0.old : $0.new) == first }),
                  let end = lines[start...].firstIndex(where: { (left ? $0.old : $0.new) == last }),
                  !lines[start...end].contains(where: { $0.kind == .hunk }) else { return nil }
            range = ReviewLineRange(side: left ? .left : .right, lines: first...last)
        }
        guard let range else { return nil }
        return review.commentTarget(path: file.filename, range: range, item: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if canReturn {
                    Button { review.singleFile = false; review.mode = .diff; review.reveal(file.filename) } label: {
                        Label("All changes", systemImage: "chevron.left")
                    }.buttonStyle(.plain).font(.caption)
                    Divider().frame(height: 14)
                }
                Image(systemName: "doc.text").foregroundStyle(Ink.faint)
                Text(file.filename).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .help(file.previousFilename.map { "\($0) → \(file.filename)" } ?? file.filename)
                Spacer(minLength: 3)
                let viewed = review.cache.viewed(on: item)
                Toggle("Viewed", isOn: Binding(get: { viewed.files[file.filename] == true }, set: { _ in
                    viewed.toggle(file.filename, item: item, client: client)
                })).toggleStyle(.checkbox).controlSize(.small)
                    .disabled(viewed.files[file.filename] == nil || viewed.pending.contains(file.filename))
                toolIcon("text.bubble", "Comment on file") {
                    review.fileComment = review.commentTarget(path: file.filename, range: nil, item: item)
                }.disabled(review.commentTarget(path: file.filename, range: nil, item: item) == nil)
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
                        CodeTextView(text: patch, path: file.filename, mode: .diff, identity: "\(item.id)/\(review.commit ?? "all")/\(file.id)/\(file.sha)/\(item.pr.diffRevision)", commentForRows: commentForRows, compose: { review.fileComment = $0 }, findOnOpen: review.findOnOpen ? { review.findOnOpen = false } : nil)
                    } else {
                        VStack(spacing: 10) {
                            PatchRecoveryRow(file: file, item: item, review: review, client: client)
                            if let previous = file.previousFilename { Text(previous + " → " + file.filename).font(.caption) }
                            Button("View full file") { review.mode = .source }
                        }
                    }
                } else if let failure { ReviewError(message: failure) { retry += 1 } }
                else if let source {
                    if source.isEmpty { Text("Empty file").foregroundStyle(Ink.dim) }
                    else { CodeTextView(text: source, path: file.filename, mode: .source, identity: "blob/" + file.sha, commentForRows: commentForRows, compose: { review.fileComment = $0 }, findOnOpen: review.findOnOpen ? { review.findOnOpen = false } : nil) }
                } else { ProgressView("Loading file…").controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.swap(reduceMotion), value: review.mode)
        }.task(id: "\(review.mode)/\(file.sha)/\(retry)") {
            source = nil
            failure = nil
            guard review.mode == .source else { return }
            do {
                let result = try await review.cache.source(file, item: item, client: client)
                if !Task.isCancelled { source = result }
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct PatchRecoveryRow: View {
    let file: ChangedFile
    let item: InboxItem
    let review: ReviewSession
    let client: GitHubClient
    var body: some View {
        let key = review.recoveryKey(file, item: item)
        let loading = review.recovering.contains(key)
        let failure = review.recoveryErrors[key]
        HStack(spacing: 8) {
            if file.additions == 0 && file.deletions == 0 {
                Text(file.previousFilename.map { "Renamed from " + $0 } ?? "No text changes reported.")
            } else {
                Button(failure == nil ? "Load diff" : "Retry") { review.startRecovery(file, item: item, client: client) }
                    .buttonStyle(.link).disabled(loading)
                Text(failure ?? (loading ? "Comparing revisions…" : "GitHub omitted this patch."))
                    .lineLimit(1).truncationMode(.tail).help(failure ?? "")
            }
        }.font(.caption).foregroundStyle(Ink.dim)

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
