import Foundation
import Testing
@testable import GitHubCore
@testable import GodsView

@Test func patchNumbersRestartAtEveryHunkAndSkipMissingNewlineMarkers() {
    let lines = PatchLine.parse("@@ -2,3 +7,2 @@ run\n before\n-first\n-last\n+new\n\\ No newline at end of file\n@@ -20,0 +30 @@\n+🌿")
    #expect(lines.map(\.old) == [nil, 2, 3, 4, nil, nil, nil, nil])
    #expect(lines.map(\.new) == [nil, 7, nil, nil, 8, nil, nil, 30])
    #expect(lines.last?.kind == .addition)
}

@Test func filteredTreeRevealsMatchesInsideCollapsedFolders() {
    let files = ["src/sub/a.swift", "src/b.txt", "README.md"].map {
        ChangedFile(filename: $0, previousFilename: nil, status: "modified", sha: "blob", additions: 2, deletions: 1, patch: nil)
    }
    let collapsed = FileTreeRow.visible(FileTreeRow.index(files), filter: "", collapsed: ["src"])
    #expect(collapsed.map(\.path) == ["src", "README.md"])
    let found = FileTreeRow.visible(FileTreeRow.index(files), filter: "A.SWIFT", collapsed: ["src"])
    #expect(found.map(\.path) == ["src", "src/sub", "src/sub/a.swift"])
    #expect(found.map(\.depth) == [0, 1, 2])
}

@MainActor @Test func commitNavigationKeepsTheFilePathAndDropsPreviousPatches() {
    let review = ReviewSession()
    review.commits = ["a", "b"].map { ReviewCommit(oid: $0, messageHeadline: $0) }
    review.path = "a.swift"
    review.snapshot = ReviewSnapshot([ChangedFile(filename: "a.swift", previousFilename: nil, status: "added", sha: "blob", additions: 1, deletions: 0, patch: "+new")])
    #expect(review.adjacentCommit(1)?.oid == "a")
    review.selectCommit("b")
    #expect(review.path == "a.swift" && review.files.isEmpty && review.filesLoading)
    #expect(review.adjacentCommit(-1)?.oid == "a" && review.adjacentCommit(1) == nil)
    review.selectCommit(nil)
    #expect(review.commit == nil)
}

private actor SlowPullFiles: CommandRunning {
    private var continuation: CheckedContinuation<Data, Never>?
    var waiting: Bool { continuation != nil }
    private let file = #"{"filename":"selected.swift","sha":"abc","status":"added","additions":1,"deletions":0,"patch":"+new"}"#

    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        if arguments.starts(with: ["auth", "token"]) { return Data("fixture".utf8) }
        if arguments.contains(where: { $0.contains("/commits/") }) {
            return Data(#"[{"files":[\#(file)]}]"#.utf8)
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() { continuation?.resume(returning: Data("[[]]".utf8)); continuation = nil }
}

@MainActor @Test func delayedPullDiffCannotOverwriteANewerCommit() async throws {
    let prJSON = """
    {"id":"id","number":1,"title":"T","repository":{"nameWithOwner":"r/p"},"url":"https://github.com/r/p/pull/1",
    "updatedAt":0,"isDraft":false,"headRefName":"head","baseRefName":"base","bodyText":"","additions":1,"deletions":0,
    "changedFiles":1,"labels":{"nodes":[]}}
    """
    let pr = try JSONDecoder().decode(PullRequest.self, from: Data(prJSON.utf8))
    let item = InboxItem(account: "r", pr: pr, queues: [.authored])
    let cli = SlowPullFiles()
    let client = GitHubClient(cli: cli)
    let review = ReviewSession()
    let pending = Task { await review.loadFiles(item, client: client) }
    for _ in 0..<100 where !(await cli.waiting) { try await Task.sleep(for: .milliseconds(2)) }
    try #require(await cli.waiting)
    review.selectCommit("new")
    await review.loadFiles(item, client: client)
    await cli.finish()
    await pending.value
    #expect(review.commit == "new" && review.path == "selected.swift" && !review.filesLoading)
}

@Test func searchNamesTheHiddenFieldThatMatched() throws {
    let data = """
    {"id":"p","number":7,"title":"Fix login","url":"https://github.com/acme/app/pull/7",
    "repository":{"nameWithOwner":"acme/app"},"author":{"login":"rivera"},"updatedAt":0,"isDraft":false,
    "headRefName":"feat/oauth-retry","baseRefName":"main","bodyText":"","additions":0,"deletions":0,
    "changedFiles":0,"labels":{"nodes":[]}}
    """
    let item = InboxItem(account: "sam", pr: try JSONDecoder().decode(PullRequest.self, from: Data(data.utf8)), queues: [])
    #expect(PRMatch.hiddenContext(item, query: "oauth") == "branch feat/oauth-retry")
    #expect(PRMatch.hiddenContext(item, query: "login rivera") == "by rivera")
    #expect(PRMatch.hiddenContext(item, query: "acme/app") == nil)
    #expect(PRMatch.hiddenContext(item, query: "") == nil)
}

@Test func diffRowsAnnounceChangeTypeAndLineNumbers() {
    let lines = PatchLine.parse("@@ -4,2 +4,2 @@\n-old\n+new\n same")
    #expect(lines[1].spokenLabel == "Removed, old line 4: old")
    #expect(lines[2].spokenLabel == "Added, new line 4: new")
    #expect(lines[3].spokenLabel == "Old line 5, new line 5: same")
}

@Test func hunkHeadersReadAsLineRangesAndChangesKeepAMarker() {
    let lines = PatchLine.parse("@@ -8,14 +8,15 @@ carousels: settled\n-old\n+new\n same")
    #expect(lines[0].hunkTitle == "Lines 8–22 (was 8–21)  ·  carousels: settled")
    #expect(PatchLine.parse("@@ -1 +1 @@")[0].hunkTitle == "Line 1")
    #expect(PatchLine.parse("@@ -0,0 +1,26 @@")[0].hunkTitle == "Added lines 1–26")
    #expect(PatchLine.parse("@@ -1,10 +0,0 @@")[0].hunkTitle == "Removed lines 1–10")
    #expect(lines[1].attributed(path: "a.txt").string.hasPrefix("   8 − old"))
    #expect(lines[2].attributed(path: "a.txt").string.hasPrefix("   8 + new"))
    #expect(lines[3].attributed(path: "a.txt").string.hasPrefix("   9   same"))
}

@Test func exactPRIdentifiersRankFirst() throws {
    func item(_ number: Int, _ title: String) throws -> InboxItem {
        let data = """
        {"id":"p\(number)","number":\(number),"title":"\(title)","url":"https://github.com/acme/app/pull/\(number)",
        "repository":{"nameWithOwner":"acme/app"},"updatedAt":0,"isDraft":false,"headRefName":"b","baseRefName":"main",
        "bodyText":"","additions":0,"deletions":0,"changedFiles":0,"labels":{"nodes":[]}}
        """
        return InboxItem(account: "sam", pr: try JSONDecoder().decode(PullRequest.self, from: Data(data.utf8)), queues: [])
    }
    let items = [try item(1234, "Bump to 12"), try item(12, "Fix login")]
    #expect(PRMatch.rankExact(items, query: "#12").map(\.pr.number) == [12, 1234])
    #expect(PRMatch.rankExact(items, query: "acme/app#12").map(\.pr.number) == [12, 1234])
    #expect(PRMatch.rankExact(items, query: "bump").map(\.pr.number) == [1234, 12])
}

@Test func gutterGrowsForFiveDigitLineNumbers() {
    let lines = PatchLine.parse("@@ -12340,2 +12340,2 @@\n-old\n+new")
    let digits = CodeTheme.digits(for: 12341)
    #expect(digits == 5)
    #expect(CodeTheme.digits(for: 87) == CodeTheme.numberColumns)
    #expect(lines[2].attributed(path: "a.txt", digits: digits).string.hasPrefix("12340 + new"))
    #expect(ReviewSnapshot([ChangedFile(filename: "a.txt", previousFilename: nil, status: "modified", sha: "s",
                                        additions: 1, deletions: 1, patch: "@@ -12340,2 +12340,2 @@\n-old\n+new")]).lineDigits == 5)
}
