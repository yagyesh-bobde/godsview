import Foundation
import GitHubCore
import Testing
@testable import GodsView

/// Separate suspensions on both sides of each credential lookup exercise the
/// same overlapping requests as a real multi-account refresh.
private actor DelayedCLI: CommandRunning {
    var failAlice = false

    var closed = false
    func closeAllPullRequests() { closed = true }
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
        return Data(#"{"data":{"reviews":\#(closed ? empty : page),"assigned":\#(empty),"authored":\#(empty)}}"#.utf8)
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

@MainActor @Test func lastAccountFilterSurvivesColdLaunchAndCanReturnToAllAccounts() async {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let directory = URL.temporaryDirectory.appending(path: suite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let disk = WorkspaceDisk(directory: directory)
    let client = GitHubClient(cli: DelayedCLI())
    let store = Workspace(client: client, disk: disk, preferences: defaults)
    await store.refresh()
    store.scope = "bob"
    let restored = Workspace(client: client, disk: disk, preferences: defaults)
    #expect(restored.scope == "bob")
    #expect(restored.selected?.account == "bob")
    #expect(restored.visible.map(\.account) == ["bob"])
    restored.scope = nil
    #expect(Workspace(client: client, disk: disk, preferences: defaults).scope == nil)
}

@MainActor @Test func hiddenRepositoriesStayOutOfCachedInboxesAndSearchAcrossAccounts() async {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let disk = WorkspaceDisk(directory: URL.temporaryDirectory.appending(path: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL.temporaryDirectory.appending(path: suite))
    }
    let client = GitHubClient(cli: DelayedCLI())
    let store = Workspace(client: client, disk: disk, preferences: defaults)
    await store.refresh()
    store.selection = store.visible.first?.id
    store.hideRepository("Example/Tools")
    #expect(store.selected == nil)
    let restored = Workspace(client: client, disk: disk, preferences: defaults)
    #expect(restored.visible.isEmpty && restored.launcherResults("").isEmpty)
    restored.showRepository("example/tools")
    #expect(restored.visible.count == 2 && restored.launcherResults("pagination").count == 2)
}

@MainActor @Test func successfulEmptyRefreshClearsThePersistedInbox() async {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = WorkspaceDisk(directory: directory)
    let cli = DelayedCLI(), workspace = Workspace(client: GitHubClient(cli: cli), disk: disk)
    await workspace.refresh()
    await cli.closeAllPullRequests()
    await workspace.refresh()
    let restored = Workspace(disk: disk)
    #expect(restored.hasCheckedInbox && restored.items.isEmpty)
    #expect(restored.accounts.count == 2)
}


@MainActor @Test func appReloadRestoresTheActiveAccountReviewAndFile() async throws {
    let client = GitHubClient(cli: DelayedCLI())
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = WorkspaceDisk(directory: directory)
    let store = Workspace(client: client, disk: disk)
    await store.refresh()
    store.scope = "bob"
    store.query = "pagination"
    store.queue = .reviews
    store.selection = try #require(store.visible.first?.id)
    store.review.tab = .discussion
    store.review.commit = "abc123"
    store.review.path = "Sources/Queue.swift"
    store.review.mode = .source
    store.review.singleFile = true
    store.review.showTree = false
    let state = try JSONEncoder().encode(WorkspaceNavigation(store))
    let restored = Workspace(client: client, disk: disk)
    try JSONDecoder().decode(WorkspaceNavigation.self, from: state).restore(in: restored)
    #expect(restored.selected?.account == "bob")
    #expect(restored.review.tab == .discussion && restored.review.commit == "abc123")
    #expect(restored.review.path == store.review.path && restored.review.mode == .source)
    #expect(restored.review.singleFile && !restored.review.showTree)
    #expect(restored.query == store.query && restored.queue == store.queue)
}

@MainActor @Test func closedPRDisappearsAcrossAccountsAndStaleSearchResults() async {
    let store = Workspace(client: GitHubClient(cli: DelayedCLI()))
    await store.refresh()
    guard let item = store.items.first else { Issue.record("Missing fixture PR"); return }
    await store.removeClosed(item)
    #expect(store.items.isEmpty)
    await store.refresh()
    #expect(store.items.isEmpty)
}

@MainActor @Test func t3ThreadActionsUseTheProjectModelAndKeepPromptsOnStdin() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let binary = folder.appending(path: "t3")
    let script = #"""
    #!/bin/sh
    set -eu
    case "$2" in
    list) echo '[{"providerInstanceId":"local","model":"example"},{"providerInstanceId":"local","model":"example"}]' ;;
    start)
        test "$3" = "/project with spaces"
        test "$4" = "-"
        case "$(cat)" in *"Review this pull request"*"https://github.com/example/tools/pull/2"*) ;; *) exit 7 ;; esac
        echo '{"threadId":"test-thread"}' ;;
    send)
        test "$3" = "test-thread"
        test "$(cat)" = 'What about $pagination?'
        echo '{"delivery":"started"}' ;;
    show) echo '{"thread":{"status":"completed","model":"example","link":null},"messages":[{"role":"assistant","text":"Example reply."}]}' ;;
    *) exit 9 ;;
    esac
    """#
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let client = try T3MCP(executable: binary)
    let store = Workspace(client: GitHubClient(cli: DelayedCLI()))
    await store.refresh()
    let item = try #require(store.items.first)
    let models = try await client.recentModels(project: "/project with spaces")
    #expect(models.count == 1)
    let ref = try await client.start(item: item, project: "/project with spaces", question: nil, model: models[0])
    try await client.send("What about $pagination?", thread: ref.id)
    let result = try await client.read(ref.id)
    #expect(!result.isWorking && result.messages.last?.text == "Example reply.")
    #expect(T3MCP.prompt(item, question: "How does paging work?").contains("Question:\nHow does paging work?"))
}

@MainActor @Test func launcherResolvesAnUnlistedPRViaTheAccountWithAccessAndRestoresIt() async throws {
    actor LinkCLI: CommandRunning {
        let base = DelayedCLI()
        var attempts: [String] = []
        func run(_ args: [String], token: String?, input: Data?) async throws -> Data {
            guard args.contains(where: { $0.contains("query LinkedPR") }) else {
                return try await base.run(args, token: token, input: input)
            }
            attempts.append(token ?? "")
            guard token == "bob" else { throw URLError(.userAuthenticationRequired) }
            return Data("""
            {"data":{"repository":{"pullRequest":{"id":"outside","number":42,"title":"A merged PR",
            "url":"https://github.com/example/tools/pull/42","repository":{"nameWithOwner":"example/tools"},
            "updatedAt":"2026-01-11T10:30:00Z","state":"MERGED","isDraft":false,"headRefName":"topic",
            "baseRefName":"main","bodyText":"","additions":2,"deletions":0,"changedFiles":1,"labels":{"nodes":[]}}}}}
            """.utf8)
        }
    }
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = WorkspaceDisk(directory: directory), cli = LinkCLI()
    let store = Workspace(client: GitHubClient(cli: cli), disk: disk)
    await store.refresh()
    store.scope = "alice"
    #expect(store.launcherResults("example/tools#2 bob").map(\.account) == ["bob"])
    let link = try #require(PullRequestLink("https://github.com/example/tools/pull/42"))
    let item = try await store.resolve(link)
    #expect(await cli.attempts == ["alice", "bob"])
    store.openFromLauncher(item)
    #expect(store.selected?.id == item.id && store.scope == "bob")
    #expect(item.pr.stateLabel == "Merged" && !item.pr.isOpen)
    #expect(store.linkedRow?.id == item.id && store.displayedIDs.contains(item.id))
    #expect(!store.items.contains { $0.id == item.id })
    #expect(store.launcherResults("merged").first?.id == item.id)
    await store.refresh()
    #expect(disk.inbox()?.linkedItem?.id == item.id)
}

@MainActor @Test func viewedStateIsOptimisticAndRollsBackAFailedMutation() async throws {
    actor ViewedCLI: CommandRunning {
        var mutations = 0
        func run(_ args: [String], token: String?, input: Data?) async throws -> Data {
            if args.starts(with: ["auth", "token"]) { return Data("fixture".utf8) }
            if args.contains(where: { $0.contains("query ViewedFiles") }) {
                return Data(#"[{"data":{"node":{"files":{"nodes":[{"path":"main.swift","viewerViewedState":"UNVIEWED"}]}}}}]"#.utf8)
            }
            mutations += 1
            try await Task.sleep(for: .milliseconds(5))
            throw URLError(.userAuthenticationRequired)
        }
    }
    let workspace = Workspace(client: GitHubClient(cli: DelayedCLI()))
    await workspace.refresh()
    let item = try #require(workspace.items.first)
    let cli = ViewedCLI(), client = GitHubClient(cli: cli)
    let state = workspace.review.cache.viewed(on: item)
    await state.refresh(item, client: client)
    state.toggle("main.swift", item: item, client: client)
    state.toggle("main.swift", item: item, client: client)
    #expect(state.files["main.swift"] == true && state.pending.contains("main.swift"))
    await state.refresh(item, client: client)
    let deadline = ContinuousClock.now + .seconds(2)
    while !state.pending.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(state.files["main.swift"] == false && state.pending.isEmpty)
    #expect(state.error != nil && workspace.review.cache.viewed(on: item) === state)
    #expect(await cli.mutations == 1)
}
