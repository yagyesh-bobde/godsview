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
        HStack(spacing: 0) {
            editorColumn
                .frame(minWidth: Workspace.minimumDiffWidth, maxWidth: .infinity, maxHeight: .infinity)
            WorkspacePane(store: store, visible: store.treeVisible, trailing: true) {
                FileTreeView(review: review, viewed: viewed, openSearch: { store.palette = .files }, width: store.sidebarWidth)
            }
            T3Column(store: store, review: review, item: item)
        }.task(id: item.pr.diffRevision) { await viewed.refresh(item, client: store.client) }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
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
            editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                // A soft fade at the right edge while long lines continue past the visible area.
                // It starts below the sticky file header and only covers the last few columns.
                .overlay(alignment: .trailing) {
                    if review.diffContinuesRight && editorPhase == .stream {
                        LinearGradient(colors: [Color(nsColor: CodeTheme.background).opacity(0), Color(nsColor: CodeTheme.background).opacity(0.9)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16).padding(.top, 24).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                // Scrolling updates the selected path. Only animate changes to what the editor shows.
                .animation(Motion.swap(reduceMotion), value: editorPhase)
                .clipped()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            commitControls.layoutPriority(-1)
            Spacer(minLength: 6)
            if !review.singleFile && !store.focusingFile && !review.files.isEmpty {
                let allFolded = review.collapsedFiles.count == review.files.count
                toolIcon(allFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                         allFolded ? "Expand all file diffs" : "Collapse all file diffs") {
                    review.toggleAllFiles()
                }
            }
            Button(action: store.toggleTree) { Image(systemName: "sidebar.right") }
                .buttonStyle(IconButtonStyle(active: store.treeVisible))
                .help("Toggle changed files sidebar (⌘L)").accessibilityLabel("Toggle changed files sidebar")
            toolIcon(store.focusingFile ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                     store.focusingFile ? "Exit full-screen file view" : "Full-screen file view (⇧⌘Return)", action: toggleFullScreen)
            if !review.filesLoading {
                WorkspaceRule(vertical: true).frame(height: 16).padding(.horizontal, 4)
                HStack(spacing: 8) {
                    Text(review.commit == nil && review.files.count < item.pr.changedFiles
                         ? "\(review.files.count) of \(item.pr.changedFiles) files" : "\(review.files.count) files")
                        .foregroundStyle(Ink.dim).lineLimit(1)
                    DiffStat(additions: review.snapshot?.additions ?? 0, deletions: review.snapshot?.deletions ?? 0)
                }.font(.system(size: 12))
            }
        }.padding(.horizontal, 12).headerRow(.controls)
    }

    private var commitControls: some View {
        let symbol = "point.topleft.down.to.point.bottomright.curvepath"
        let title = review.selectedCommit?.messageHeadline ?? "All commits"
        let hint = "Choose a commit (⇧⌘O)"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Button { store.palette = .commits } label: {
                    HStack(spacing: 7) {
                        Image(systemName: symbol).foregroundStyle(Ink.dim)
                        Text(title).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                        if let commit = review.selectedCommit {
                            Text(commit.shortID).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Ink.dim)
                    }
                }.buttonStyle(ActionButtonStyle(kind: .secondary)).help(hint)
                HStack(spacing: 0) {
                    ForEach([-1, 1], id: \.self) { direction in
                        toolIcon(direction < 0 ? "chevron.left" : "chevron.right",
                                 direction < 0 ? "Previous commit (⌥⌘←)" : "Next commit (⌥⌘→)") {
                            if let next = review.adjacentCommit(direction) { review.selectCommit(next.oid) }
                        }.disabled(review.adjacentCommit(direction) == nil)
                    }
                }
            }.fixedSize(horizontal: true, vertical: false)
            Button { store.palette = .commits } label: { Image(systemName: symbol) }
                .buttonStyle(IconButtonStyle(active: review.commit != nil))
                .help("\(title) · \(hint)").accessibilityLabel("\(hint), \(title)")
        }.frame(minWidth: ControlSize.regular, alignment: .leading)
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
            DiffStream(snapshot: snapshot, review: review, collapsed: review.collapsedFiles, viewed: viewed, viewedVersion: viewed.version, reveal: review.revealRequest, fontSize: store.codeFontSize, item: item, client: store.client)
                .transition(.opacity)
        } else if let file = review.selectedFile {
            FileEditor(file: file, item: item, review: review, client: store.client, fontSize: store.codeFontSize, canReturn: !store.focusingFile).id(file.sha + "/" + file.id)
                .transition(.opacity)
        } else {
            ContentUnavailableView("No changed files", systemImage: "doc.on.doc").transition(.opacity)
        }
    }
}

private struct FileEditor: View {
    let file: ChangedFile
    let item: InboxItem
    @Bindable var review: ReviewSession
    let client: GitHubClient
    let fontSize: CGFloat
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
                        CodeTextView(text: patch, path: file.filename, mode: .diff, identity: "\(item.id)/\(review.commit ?? "all")/\(file.id)/\(file.sha)/\(item.pr.diffRevision)", fontSize: fontSize, commentForRows: commentForRows, compose: { review.fileComment = $0 }, findOnOpen: review.findOnOpen ? { review.findOnOpen = false } : nil)
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
                    else { CodeTextView(text: source, path: file.filename, mode: .source, identity: "blob/" + file.sha, fontSize: fontSize, commentForRows: commentForRows, compose: { review.fileComment = $0 }, findOnOpen: review.findOnOpen ? { review.findOnOpen = false } : nil) }
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
        }.font(.system(size: 11, weight: .medium, design: .monospaced)).fixedSize()
    }
}

@MainActor func toolIcon(_ symbol: String, _ help: String, size: CGFloat = ControlSize.regular,
                         action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol) }
        .buttonStyle(IconButtonStyle(size: size)).help(help).accessibilityLabel(help)
}
