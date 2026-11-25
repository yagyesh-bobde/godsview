import Foundation
import GitHubCore

/// Immutable data prepared off the UI thread, shared by the tree, quick-open and diff list.
final class ReviewSnapshot: Sendable {
    let files: [ChangedFile]
    let lines: [[PatchLine]]
    let indices: [String: Int]
    let tree: [FileTreeRow]
    let additions: Int
    let deletions: Int
    let longestLine: Int
    /// Digits of the largest line number in any file, for one aligned gutter width.
    let lineDigits: Int
    let cost: Int

    init(_ files: [ChangedFile]) {
        self.files = files
        var lookup: [String: Int] = [:]
        var width = 0, bytes = 0, largest = 0
        lines = files.enumerated().map { i, file in
            lookup[file.filename] = i
            let lines = file.patch.flatMap { $0.isEmpty ? nil : PatchLine.parse($0) } ?? []
            for line in lines {
                largest = max(largest, line.old ?? 0, line.new ?? 0)
                let length = line.text.utf8.count
                // Tabs can advance up to eight monospace columns.
                width = max(width, length + 7 * line.text.utf8.reduce(0) { $0 + ($1 == 9 ? 1 : 0) })
                bytes += 96 + 2 * length
            }
            return lines
        }
        indices = lookup
        longestLine = width
        lineDigits = CodeTheme.digits(for: largest)
        cost = bytes + files.count * 384
        tree = FileTreeRow.index(files)
        additions = files.reduce(0) { $0 + $1.additions }
        deletions = files.reduce(0) { $0 + $1.deletions }
    }
}

/// Coalesce simultaneous requests. Failed loads are immediately eligible for retry.
private actor ReviewValues<Value: Sendable> {
    private final class Box { let value: Value; init(_ value: Value) { self.value = value } }
    private let cached = NSCache<NSString, Box>()
    private var pending: [String: Task<Value, Error>] = [:]
    init(bytes: Int, count: Int) {
        cached.totalCostLimit = bytes
        cached.countLimit = count
    }
    func replace(_ value: Value, key: String, cost: Int, persist: @Sendable () -> Void) {
        cached.setObject(Box(value), forKey: key as NSString, cost: cost)
        persist()
    }

    func value(_ key: String, cost: @Sendable (Value) -> Int,
               load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let value = cached.object(forKey: key as NSString) { return value.value }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await load() }
        pending[key] = task
        defer { pending[key] = nil }
        let result = try await task.value
        cached.setObject(Box(result), forKey: key as NSString, cost: cost(result))
        return result
    }
}

final class ReviewCache: Sendable {
    private let disk: WorkspaceDisk?
    init(disk: WorkspaceDisk? = nil) { self.disk = disk }

    @MainActor private let viewedByPR: NSCache<NSString, ViewedFiles> = {
        let cache = NSCache<NSString, ViewedFiles>()
        cache.countLimit = 64
        return cache
    }()

    @MainActor func viewed(on item: InboxItem) -> ViewedFiles {
        let key = item.id as NSString
        if let cached = viewedByPR.object(forKey: key) { return cached }
        let state = ViewedFiles()
        viewedByPR.setObject(state, forKey: key)
        return state
    }

    private let diffs = ReviewValues<ReviewSnapshot>(bytes: 96 << 20, count: 24)
    private let histories = ReviewValues<[ReviewCommit]>(bytes: 4 << 20, count: 64)
    private let blobs = ReviewValues<String>(bytes: 32 << 20, count: 100)

    func diff(_ item: InboxItem, commit: String?, client: GitHubClient) async throws -> ReviewSnapshot {
        let key = item.id + "/" + (commit ?? item.pr.diffRevision)
        return try await diffs.value(key, cost: { $0.cost }) {
            if let saved = self.disk?.files(for: key) { return ReviewSnapshot(saved) }
            let files = try await client.files(on: item, commit: commit)
            self.disk?.store(files, for: key)
            return ReviewSnapshot(files)
        }
    }

    func remember(_ snapshot: ReviewSnapshot, item: InboxItem, commit: String?) async {
        let key = item.id + "/" + (commit ?? item.pr.diffRevision)
        await diffs.replace(snapshot, key: key, cost: snapshot.cost) {
            self.disk?.store(snapshot.files, for: key)
        }
    }

    func history(_ item: InboxItem, client: GitHubClient) async throws -> [ReviewCommit] {
        try await histories.value(item.id + "/" + item.pr.diffRevision, cost: { $0.count * 256 }) {
            try await client.commits(on: item)
        }
    }

    private let recovered = ReviewValues<String>(bytes: 32 << 20, count: 50)
    func patch(_ file: ChangedFile, item: InboxItem, commit: String?, client: GitHubClient) async throws -> String {
        let key = [item.id, commit ?? item.pr.diffRevision, file.sha, file.filename].joined(separator: "/")
        return try await recovered.value(key, cost: { $0.utf8.count }) {
            try await client.recoverPatch(for: file, on: item, commit: commit)
        }
    }

    func source(_ file: ChangedFile, item: InboxItem, client: GitHubClient) async throws -> String {
        try await blobs.value(item.account + "/" + item.pr.repository.nameWithOwner + "/" + file.sha, cost: { $0.utf8.count }) {
            try await client.source(of: file, on: item)
        }
    }
}
