import Foundation
import GitHubCore
import Observation

enum ReviewTab: String, CaseIterable { case summary = "Summary", discussion = "Discussion", code = "Code" }
enum FileMode: String, CaseIterable { case diff = "Diff", source = "File" }
enum PaletteMode: String, Identifiable { case global, files, commits; var id: Self { self } }

@MainActor @Observable
final class ReviewSession {
    var tab = ReviewTab.code
    var mode = FileMode.diff
    var commit: String?
    var commits: [ReviewCommit] = []
    var files: [ChangedFile] = []
    var path: String?
    var filter = ""
    var filesLoading = true
    var commitsLoading = true
    var filesError: String?
    var commitsError: String?
    var retry = 0
    var showTree = true
    private var snapshots: [String: [ChangedFile]] = [:]
    private var snapshotDate: Date?
    var selectedFile: ChangedFile? { files.first { $0.filename == path } }
    var selectedCommit: ReviewCommit? { commits.first { $0.oid == commit } }

    func selectCommit(_ id: String?) {
        tab = .code
        guard commit != id else { return }
        commit = id
        files = []
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
        guard let index = files.firstIndex(where: { $0.filename == path }) else { return nil }
        let next = index + delta
        return files.indices.contains(next) ? files[next] : nil
    }

    func loadCommits(_ item: InboxItem, client: GitHubClient) async {
        commitsLoading = true
        commitsError = nil
        do {
            let result = try await client.commits(on: item)
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
        if snapshotDate != item.pr.updatedAt {
            snapshots.removeAll()
            snapshotDate = item.pr.updatedAt
        }
        let requested = commit
        let key = requested ?? "all"
        filesLoading = true
        filesError = nil
        do {
            let result: [ChangedFile]
            if let cached = snapshots[key] { result = cached }
            else { result = try await client.files(on: item, commit: requested) }
            guard !Task.isCancelled, requested == commit else { return }
            if snapshots.count >= 6, snapshots[key] == nil { snapshots.removeAll() }
            snapshots[key] = result
            files = result
            if !result.contains(where: { $0.filename == path }) {
                path = (result.first { $0.patch?.isEmpty == false } ?? result.first)?.filename
            }
        } catch {
            guard !Task.isCancelled, requested == commit else { return }
            filesError = error.localizedDescription
            files = []
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

    static func rows(files: [ChangedFile], filter: String, collapsed: Set<String>) -> [Self] {
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
        for file in sorted where filter.isEmpty || file.filename.localizedCaseInsensitiveContains(filter) {
            var path = ""
            let parts = file.filename.split(separator: "/")
            for (index, part) in parts.enumerated() {
                if !path.isEmpty { path += "/" }
                path += part
                let leaf = index == parts.count - 1
                if leaf || folders.insert(path).inserted {
                    result.append(Self(path: path, name: String(part), depth: index, file: leaf ? file : nil))
                }
                if !leaf && filter.isEmpty && collapsed.contains(path) { break }
            }
        }
        return result
    }
}
