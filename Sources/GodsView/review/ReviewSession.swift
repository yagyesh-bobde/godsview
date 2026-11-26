import SwiftUI
import Foundation
import GitHubCore
import Observation

enum ReviewTab: String, Codable, CaseIterable { case summary = "Summary", discussion = "Discussion", code = "Code" }
enum FileMode: String, Codable, CaseIterable { case diff = "Diff", source = "File" }
enum PaletteMode: String, Identifiable { case global, files, commits; var id: Self { self } }

enum ReviewSheet: String, Identifiable {
    case comment, close, merge, ask, aiReview
    var id: Self { self }
}

@MainActor @Observable
final class ReviewSession {
    var fileComment: FileCommentTarget?
    /// Text for the next Ask T3 sheet, set by "Ask T3 about selected lines".
    @ObservationIgnored private var askPrefill: String?
    func askAbout(_ text: String) {
        askPrefill = text
        sheet = .ask
    }
    func takeAskPrefill() -> String? {
        defer { askPrefill = nil }
        return askPrefill
    }
    func commentTarget(path: String, range: ReviewLineRange?, item: InboxItem) -> FileCommentTarget? {
        guard loadedScope == (commit ?? item.pr.diffRevision), let sha = commit ?? item.pr.headRefOid,
              snapshot?.indices[path] != nil else { return nil }
        return FileCommentTarget(path: path, commit: sha, range: range)
    }

    var sheet: ReviewSheet?
    var tab = ReviewTab.code
    var mode = FileMode.diff
    var commit: String?
    var commits: [ReviewCommit] = []
    let cache: ReviewCache
    init(cache: ReviewCache = ReviewCache()) { self.cache = cache }
    var snapshot: ReviewSnapshot?
    var files: [ChangedFile] { snapshot?.files ?? [] }
    var collapsedFiles: Set<String> = []
    var revealRequest = 0
    var singleFile = false
    var automaticallyFoldHeader = true
    var headerCollapsed = false
    /// How far the folded header rows travel: the context and navigation rows.
    static let foldDistance: CGFloat = WorkspaceHeaderRow.context.rawValue + WorkspaceHeaderRow.navigation.rawValue
    /// 0 = header in place, 1 = slid up under the toolbar. Only offsets and opacity read it, so
    /// animating it never re-lays out the window; the real fold is one layout pass at the end.
    var headerSlide: Double = 0
    @ObservationIgnored private var foldTarget: Bool?
    @ObservationIgnored private var folding: Task<Void, Never>?

    /// Folds or unfolds the header while the diff scrolls, smoothly and without per-frame layout.
    func scrollFold(_ fold: Bool, reduceMotion: Bool) {
        guard fold != (foldTarget ?? headerCollapsed) else { return }
        folding?.cancel()
        var instant = Transaction()
        instant.disablesAnimations = true
        if reduceMotion {
            foldTarget = nil
            withTransaction(instant) { headerCollapsed = fold; headerSlide = 0 }
            return
        }
        foldTarget = fold
        let duration = 0.2
        if fold {
            withAnimation(.easeOut(duration: duration)) { headerSlide = 1 }
            folding = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                guard let self else { return }
                withTransaction(instant) { self.headerCollapsed = true; self.headerSlide = 0 }
                self.foldTarget = nil
            }
        } else {
            // Unfold in one layout pass with the rows still slid away, then slide them in.
            if headerCollapsed { withTransaction(instant) { headerCollapsed = false; headerSlide = 1 } }
            folding = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: duration)) { self.headerSlide = 0 }
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                self.foldTarget = nil
            }
        }
    }
    var findOnOpen = false
    /// True while the diff has wider lines to the right of the visible area.
    var diffContinuesRight = false
    func reveal(_ path: String) {
        self.path = path
        collapsedFiles.remove(path)
        revealRequest += 1
    }
    func toggleAllFiles() {
        collapsedFiles = collapsedFiles.count == files.count ? [] : Set(files.map(\.filename))
    }

    var path: String?
    var filter = ""
    var filesLoading = true
    var commitsLoading = true
    var filesError: String?
    var commitsError: String?
    var retry = 0
    var showTree = true
    var selectedFile: ChangedFile? { path.flatMap { snapshot?.indices[$0] }.map { files[$0] } }
    var selectedCommit: ReviewCommit? { commits.first { $0.oid == commit } }

    var recovering: Set<String> = []
    var recoveryErrors: [String: String] = [:]

    func startRecovery(_ file: ChangedFile, item: InboxItem, client: GitHubClient) {
        let requested = commit
        guard loadedScope == (requested ?? item.pr.diffRevision) else { return }
        let key = recoveryKey(file, item: item)
        guard recovering.insert(key).inserted else { return }
        recoveryErrors[key] = nil
        Task {
            defer { recovering.remove(key) }
            do { try await recover(file, item: item, requested: requested, client: client) }
            catch { recoveryErrors[key] = error.localizedDescription }
        }
    }

    func recoveryKey(_ file: ChangedFile, item: InboxItem) -> String {
        [item.id, commit ?? item.pr.diffRevision, file.sha, file.filename].joined(separator: "/")
    }

    private func recover(_ file: ChangedFile, item: InboxItem, requested: String?, client: GitHubClient) async throws {
        let scope = requested ?? item.pr.diffRevision
        let patch = try await cache.patch(file, item: item, commit: requested, client: client)
        while !Task.isCancelled, scope == loadedScope, requested == commit, let previous = snapshot,
              let index = previous.indices[file.filename], previous.files[index] == file {
            let updated = await Task.detached(priority: .userInitiated) {
                var files = previous.files
                files[index] = file.withPatch(patch)
                return ReviewSnapshot(files)
            }.value
            guard !Task.isCancelled, scope == loadedScope, requested == commit else { return }
            if snapshot === previous {
                snapshot = updated
                await cache.remember(updated, item: item, commit: requested)
                return
            }
        }
    }

    private var loadedScope: String?
    func selectCommit(_ id: String?) {
        tab = .code
        guard commit != id else { return }
        commit = id
        snapshot = nil
        filesLoading = true
        filesError = nil
        filter = ""
    }

    func adjacentCommit(_ delta: Int) -> ReviewCommit? {
        let index = commit.flatMap { id in commits.firstIndex { $0.oid == id } } ?? -1
        let next = index + delta
        return commits.indices.contains(next) ? commits[next] : nil
    }

    func adjacentFile(_ delta: Int) -> ChangedFile? {
        guard let path, let index = snapshot?.indices[path] else { return nil }
        let next = index + delta
        return files.indices.contains(next) ? files[next] : nil
    }

    func loadCommits(_ item: InboxItem, client: GitHubClient) async {
        commitsLoading = true
        commitsError = nil
        do {
            let result = try await cache.history(item, client: client)
            guard !Task.isCancelled else { return }
            commits = result
            if let commit, !result.contains(where: { $0.oid == commit }) { selectCommit(nil) }
        } catch {
            guard !Task.isCancelled else { return }
            commitsError = error.localizedDescription
        }
        commitsLoading = false
    }

    func loadFiles(_ item: InboxItem, client: GitHubClient) async {
        let requested = commit
        filesLoading = snapshot == nil
        filesError = nil
        do {
            let loaded = try await cache.diff(item, commit: requested, client: client)
            guard !Task.isCancelled, requested == commit else { return }
            loadedScope = requested ?? item.pr.diffRevision
            snapshot = loaded
            collapsedFiles.formIntersection(loaded.indices.keys)
            let result = loaded.files
            if !result.contains(where: { $0.filename == path }) {
                path = (result.first { $0.patch?.isEmpty == false } ?? result.first)?.filename
            }
        } catch {
            guard !Task.isCancelled, requested == commit else { return }
            filesError = error.localizedDescription
            // Retain the last successful snapshot if revalidation fails.
        }
        filesLoading = false
    }
}

/// Emit a folder once, preserving the complete Git path as the selection key.
struct FileTreeRow: Identifiable {
    let path: String
    let name: String
    let depth: Int
    let file: ChangedFile?
    var id: String { (file == nil ? "dir/" : "file/") + path }

    static func index(_ files: [ChangedFile]) -> [Self] {
        var folders = Set<String>()
        var result: [Self] = []
        let sorted = files.sorted { lhs, rhs in
            let a = lhs.filename.split(separator: "/"), b = rhs.filename.split(separator: "/")
            for i in 0..<min(a.count, b.count) where a[i] != b[i] {
                if (i == a.count - 1) != (i == b.count - 1) { return i != a.count - 1 }
                return a[i] < b[i]
            }
            return a.count < b.count
        }
        for file in sorted {
            var path = ""
            let parts = file.filename.split(separator: "/")
            for (index, part) in parts.enumerated() {
                if !path.isEmpty { path += "/" }
                path += part
                let leaf = index == parts.count - 1
                if leaf || folders.insert(path).inserted {
                    result.append(Self(path: path, name: String(part), depth: index, file: leaf ? file : nil))
                }
            }
        }
        return result
    }
}

extension FileTreeRow {
    static func visible(_ index: [Self], filter: String, collapsed: Set<String>) -> [Self] {
        if filter.isEmpty && collapsed.isEmpty { return index }
        var result: [Self] = []
        var parents: [Self] = []
        var hiddenDepth: Int?
        var emitted = Set<String>()
        for row in index {
            if filter.isEmpty {
                if let hiddenDepth, row.depth > hiddenDepth { continue }
                hiddenDepth = row.file == nil && collapsed.contains(row.path) ? row.depth : nil
                result.append(row)
            } else {
                while let parent = parents.last, parent.depth >= row.depth { parents.removeLast() }
                if row.file == nil { parents.append(row) }
                else if row.path.localizedCaseInsensitiveContains(filter) {
                    for parent in parents where emitted.insert(parent.path).inserted { result.append(parent) }
                    result.append(row)
                }
            }
        }
        return result
    }
}
