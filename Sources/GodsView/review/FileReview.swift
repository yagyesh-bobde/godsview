import Foundation
import GitHubCore
import Observation

struct FileCommentTarget: Identifiable {
    let id = UUID()
    let path: String
    let commit: String
    let range: ReviewLineRange?

    var description: String {
        guard let range else { return path }
        let start = range.lines.lowerBound, end = range.lines.upperBound
        return "\(path) · \(range.side == .left ? "old" : "new") \(start == end ? "line \(end)" : "lines \(start)–\(end)")"
    }
}

extension PatchLine {
    /// A GitHub review range belongs to one side of one continuous diff hunk.
    static func commentRange(_ lines: ArraySlice<PatchLine>) -> ReviewLineRange? {
        guard !lines.isEmpty else { return nil }
        let side: ReviewLineRange.Side = lines.contains { $0.kind == .deletion } ? .left : .right
        var first: Int?, last: Int?
        for line in lines {
            guard let number = side == .left ? line.old : line.new,
                  last.map({ $0 + 1 == number }) ?? true else { return nil }
            if first == nil { first = number }
            last = number
        }
        guard let first, let last else { return nil }
        return ReviewLineRange(side: side, lines: first...last)
    }
}

@MainActor @Observable
final class ViewedFiles {
    private(set) var files: [String: Bool] = [:]
    private(set) var pending: Set<String> = []
    private(set) var error: String?
    private(set) var version = 0
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var edits: [String: Int] = [:]

    func refresh(_ item: InboxItem, client: GitHubClient) async {
        let request = UUID(), start = version, alreadyPending = pending
        loadID = request
        do {
            var fetched = try await client.viewedFiles(on: item)
            guard loadID == request, !Task.isCancelled else { return }
            for (path, change) in edits where change > start || alreadyPending.contains(path) || pending.contains(path) {
                fetched[path] = files[path]
            }
            files = fetched
            if version == start && alreadyPending.isEmpty { error = nil }
            version += 1
        } catch {
            if loadID == request && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func toggle(_ path: String, item: InboxItem, client: GitHubClient) {
        guard let previous = files[path], pending.insert(path).inserted else { return }
        files[path] = !previous
        version += 1
        edits[path] = version
        Task {
            do { try await client.setViewed(!previous, path: path, on: item) }
            catch {
                files[path] = previous
                self.error = error.localizedDescription
            }
            pending.remove(path)
            version += 1
            edits[path] = version
        }
    }
}
