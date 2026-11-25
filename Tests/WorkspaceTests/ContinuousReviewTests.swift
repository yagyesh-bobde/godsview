import Foundation
import Testing
@testable import GitHubCore
@testable import GodsView

private func file(_ path: String, _ patch: String?) -> ChangedFile {
    ChangedFile(filename: path, previousFilename: nil, status: "modified", sha: "blob", additions: 1, deletions: 1, patch: patch)
}

@Test func virtualRowsCoverEveryFileIncludingEmptyPatches() {
    let files = (0..<555).map { file("f\($0)", $0 == 0 ? nil : "@@ -1 +1 @@\n-before\n+after") }
    let snapshot = ReviewSnapshot(files)
    let rows = DiffRows(snapshot, collapsed: ["f1"])
    #expect(rows.count == 2 + 1 + 553 * 4)
    for index in files.indices {
        let row = rows.starts[index]
        #expect(rows.location(row)?.file == index)
        #expect(rows.location(row)?.line == -1)
    }
    #expect(rows.location(rows.count - 1)?.file == 554)
    #expect(rows.location(rows.count - 1)?.line == 2)
    #expect(rows.location(rows.count) == nil)
    #expect(DiffRows(snapshot, collapsed: Set(files.map(\.filename))).count == 555)
}

@Test func exactFileBasenamesLeadSearchAndCollapsedTreeFilters() {
    let files = ["counting/test.ts", "src/account.ts", "dir/counter.ts", "lib/count.ts", "first.md"].map { file($0, nil) }
    #expect(FileSearch.matches(files, query: "count").map(\.filename).first == "lib/count.ts")
    #expect(FileSearch.matches(files, query: "COUNT.TS").map(\.filename) == ["lib/count.ts", "src/account.ts"])
    let tree = ReviewSnapshot(files).tree
    #expect(FileTreeRow.visible(tree, filter: "COUNT.TS", collapsed: ["lib"]).compactMap(\.file).map(\.filename) == ["lib/count.ts", "src/account.ts"])
}

@Test func numberHintsFollowViewportOrder() {
    let frames = Dictionary(uniqueKeysWithValues: (0..<15).map { ("pr-\($0)", CGRect(x: 0, y: ($0 - 2) * 40, width: 200, height: 40)) })
    #expect(SidebarRowFrames.shortcuts(frames, height: 420) == (2...10).map { "pr-\($0)" })
}

private actor CacheCLI: CommandRunning {
    var reads = 0
    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        if arguments.starts(with: ["auth", "token"]) { return Data("credential".utf8) }
        reads += 1
        try await Task.sleep(for: .milliseconds(5))
        if arguments.contains(where: { $0.contains("git/blobs") }) { return Data("source".utf8) }
        return Data("[[]]".utf8)
    }
}

@Test func cachedReviewCoalescesRequestsAndRevalidatesBothSidesOfDiff() async throws {
    func item(_ base: String, _ head: String, account: String = "alice", updated: Int = 0) throws -> InboxItem {
        let data = """
        {"id":"test","number":42,"title":"T","url":"https://github.com/example/repo/pull/42",
        "repository":{"nameWithOwner":"example/repo"},"updatedAt":\(updated),"isDraft":false,
        "headRefName":"branch","baseRefName":"main","headRefOid":"\(head)","baseRefOid":"\(base)",
        "bodyText":"","additions":0,"deletions":0,"changedFiles":0,"labels":{"nodes":[]}}
        """
        return InboxItem(account: account, pr: try JSONDecoder().decode(PullRequest.self, from: Data(data.utf8)), queues: [.authored])
    }
    let cli = CacheCLI()
    let client = GitHubClient(cli: cli)
    let cache = ReviewCache()
    let first = try item("a", "b")
    let concurrent = Task { try await cache.diff(first, commit: nil, client: client) }
    let original = try await cache.diff(first, commit: nil, client: client)
    #expect(try await concurrent.value === original)
    #expect(try await cache.diff(item("a", "b", updated: 100), commit: nil, client: client) === original)
    #expect(await cli.reads == 1)
    _ = try await cache.diff(item("a", "c"), commit: nil, client: client)
    _ = try await cache.diff(item("x", "b"), commit: nil, client: client)
    _ = try await cache.diff(item("a", "b", account: "bob"), commit: nil, client: client)
    #expect(await cli.reads == 4)
    let blob = file("src/main.swift", nil)
    _ = try await cache.source(blob, item: first, client: client)
    _ = try await cache.source(blob, item: item("x", "c"), client: client)
    #expect(await cli.reads == 5)
}
