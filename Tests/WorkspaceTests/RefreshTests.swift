import Foundation
import GitHubCore
import Testing
@testable import GodsView

/// Separate suspensions on both sides of each credential lookup exercise the
/// same overlapping requests as a real multi-account refresh.
private actor DelayedCLI: CommandRunning {
    var failAlice = false

    func breakAliceConnection() { failAlice = true }

    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        if arguments.starts(with: ["auth", "status"]) {
            return Data("""
            {"hosts":{"github.com":[{"login":"alice","active":true,"state":"success"},
            {"login":"bob","active":false,"state":"success"}]}}
            """.utf8)
        }
        try await Task.sleep(for: .milliseconds(2))
        if arguments.starts(with: ["auth", "token"]) { return Data((arguments.last ?? "").utf8) }
        if failAlice && token == "alice" { throw URLError(.notConnectedToInternet) }
        let page = """
        {"nodes":[{"id":"same-pr","number":2,"title":"Add pagination","url":"https://github.com/example/tools/pull/2",
        "repository":{"nameWithOwner":"example/tools"},"author":{"login":"dev"},"updatedAt":"2026-01-10T07:22:01Z",
        "isDraft":false,"headRefName":"changes","baseRefName":"main","bodyText":"","additions":1,"deletions":0,
        "changedFiles":1,"labels":{"nodes":[]}}],"pageInfo":{"hasNextPage":false}}
        """
        let empty = #"{"nodes":[],"pageInfo":{"hasNextPage":false}}"#
        return Data(#"{"data":{"reviews":\#(page),"assigned":\#(empty),"authored":\#(empty)}}"#.utf8)
    }
}

@MainActor @Test func refreshWaitsForEveryAccountAndPreservesLastSuccessfulResult() async {
    let cli = DelayedCLI()
    let workspace = Workspace(client: GitHubClient(cli: cli))
    for _ in 0..<20 {
        await workspace.refresh()
        #expect(Set(workspace.items.map(\.account)) == ["alice", "bob"])
        #expect(workspace.issues.isEmpty)
        #expect(!workspace.refreshing)
    }
    workspace.scope = "bob"
    workspace.queue = .reviews
    workspace.query = "PAGINATION #2"
    #expect(workspace.visible.map(\.account) == ["bob"])
    workspace.queue = .authored
    #expect(workspace.visible.isEmpty)
    await cli.breakAliceConnection()
    await workspace.refresh()
    #expect(workspace.issues.keys.sorted() == ["alice"])
    #expect(workspace.items.count == 2)
}

@MainActor @Test func relaunchRestoresTheAccountScopedInboxBeforeNetworkAccess() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = WorkspaceDisk(directory: directory)
    let cli = DelayedCLI(), client = GitHubClient(cli: cli)
    let first = Workspace(client: client, disk: disk)
    await first.refresh()
    let restored = Workspace(client: client, disk: disk)
    #expect(restored.items.map(\.id) == first.items.map(\.id))
    #expect(restored.selected != nil)
    #expect(restored.lastRefresh == first.lastRefresh)
    await cli.breakAliceConnection()
    await restored.refresh()
    #expect(restored.items.count == 2)
    #expect(disk.inbox()?.items.count == 2)
}
