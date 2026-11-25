import Foundation
import Testing
@testable import GitHubCore

private actor FixtureCLI: CommandRunning {
    struct Call: Sendable {
        let arguments: [String]
        let token: String?
        let input: Data?
    }
    var calls: [Call] = []

    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        calls.append(Call(arguments: arguments, token: token, input: input))
        if arguments.starts(with: ["auth", "token"]) { return Data("fixture-credential\n".utf8) }
        let file = #"{"filename":"Sources/Queue.swift","previous_filename":"Queue.swift","sha":"blob-a","status":"renamed","additions":4,"deletions":2}"#
        if arguments.contains(where: { $0.contains("/files?") }) {
            return Data(#"[[],[\#(file)]]"#.utf8)
        }
        if arguments.contains(where: { $0.contains("/commits/c2?") }) {
            return Data(#"[{"files":[]},{"files":[\#(file)]}]"#.utf8)
        }
        if arguments.contains(where: { $0.contains("query History") }) {
            func page(_ oid: String) -> String {
                #"{"data":{"node":{"commits":{"nodes":[{"commit":{"oid":"\#(oid)","messageHeadline":"Fix queue"}}]}}}}"#
            }
            return Data(("[\(page("c1")),\(page("c2"))]").utf8)
        }
        if arguments.contains("repos/example/tool/git/commits/c2") { return Data(#"{"parents":[{"sha":"parent-sha"}]}"#.utf8) }
        if arguments.contains("repos/example/tool/contents/Queue.swift?ref=parent-sha") { return Data("before\n".utf8) }
        if arguments.contains("repos/example/tool/git/blobs/blob-a") { return Data("full file\n".utf8) }
        guard arguments.contains("graphql") else { return Data() }
        let pr = """
        {"id":"node-7","number":7,"title":"Fix pagination","url":"https://github.com/example/tool/pull/7",
        "repository":{"nameWithOwner":"example/tool"},"author":null,"updatedAt":"2026-01-10T07:22:01Z",
        "isDraft":false,"reviewDecision":null,"headRefName":"fix","baseRefName":"main","bodyText":"",
        "additions":4,"deletions":2,"changedFiles":1,"labels":{"nodes":[]}}
        """
        let page = #"{"nodes":[\#(pr)],"pageInfo":{"hasNextPage":false}}"#
        let empty = #"{"nodes":[],"pageInfo":{"hasNextPage":true}}"#
        return Data(#"{"data":{"reviews":\#(page),"authored":\#(empty),"assigned":\#(page)}}"#.utf8)
    }
}

@Test func inboxMergesRolesWithinEachAccount() async throws {
    let client = GitHubClient(cli: FixtureCLI())
    let first = try await client.inbox(for: "alice")
    let second = try await client.inbox(for: "bob")
    #expect(first.items.count == 1)
    #expect(first.items.first?.queues == [.assigned, .reviews])
    #expect(first.items.first?.id != second.items.first?.id)
    #expect(first.limited)
}

@Test func commentUsesSelectedIdentityAndPreservesText() async throws {
    let cli = FixtureCLI()
    let client = GitHubClient(cli: cli)
    let inbox = try await client.inbox(for: "alice")
    let item = try #require(inbox.items.first)
    let body = "First line\n\nA \"quoted\" $value"
    try await client.comment(body, on: item)
    let calls = await cli.calls
    #expect(calls[2].arguments == ["auth", "token", "--hostname", "github.com", "--user", "alice"])
    let post = try #require(calls.last)
    #expect(post.token == "fixture-credential")
    #expect(post.arguments.contains("repos/example/tool/issues/7/comments"))
    let payload = try #require(post.input)
    #expect(try JSONDecoder().decode([String: String].self, from: payload) == ["body": body])
    await #expect(throws: CLIError.self) { try await client.comment("  ", on: item) }
    #expect(await cli.calls.count == 4)
}

@Test func reviewLoadsEveryPageAndUsesTheFileBlobForTheSelectedAccount() async throws {
    let cli = FixtureCLI()
    let client = GitHubClient(cli: cli)
    let inbox = try await client.inbox(for: "alice")
    let item = try #require(inbox.items.first)
    let files = try await client.files(on: item)
    let commits = try await client.commits(on: item)
    #expect(commits.map(\.oid) == ["c1", "c2"])
    let commitFiles = try await client.files(on: item, commit: commits.last?.oid)
    #expect(commitFiles == files)
    let file = try #require(commitFiles.first)
    #expect(file.previousFilename == "Queue.swift" && file.patch == nil)
    #expect(try await client.source(of: file, on: item) == "full file\n")
    let reads = await cli.calls.filter { $0.arguments.first == "api" }
    #expect(reads.allSatisfy { $0.token == "fixture-credential" })
    #expect(reads.filter { $0.arguments.contains("--paginate") }.count == 3)
}

@Test func reconstructsLargeMissingTextPatchAndPreservesEndOfFile() throws {
    let prefix = (0..<15000).map { "dependency-\($0)" }.joined(separator: "\n")
    let patch = try unifiedPatch(before: prefix + "\nold", after: prefix + "\nnew\n")
    #expect(patch.hasPrefix("@@"))
    #expect(patch.contains("-old\n\\ No newline at end of file\n+new"))
}

@Test func recoversRenamedFileAgainstFirstParentOfSelectedCommit() async throws {
    let cli = FixtureCLI(), client = GitHubClient(cli: cli)
    let inbox = try await client.inbox(for: "alice")
    let item = try #require(inbox.items.first)
    let files = try await client.files(on: item, commit: "c2")
    let file = try #require(files.first)
    let patch = try await client.recoverPatch(for: file, on: item, commit: "c2")
    #expect(patch.contains("-before\n+full file"))
}

@Test func prActionsUseTheSelectedAccountAndGuardTheMergeHead() async throws {
    actor Actions: CommandRunning {
        var calls: [[String]] = []
        func run(_ args: [String], token: String?, input: Data?) async throws -> Data {
            calls.append(args)
            if args.starts(with: ["auth","token"]) { return Data("fixture".utf8) }
            #expect(token == "fixture")
            if args.contains("PUT") { return Data(#"{"merged":true}"#.utf8) }
            return Data(#"{"state":"closed"}"#.utf8)
        }
    }
    let fixture = try await GitHubClient(cli: FixtureCLI()).inbox(for: "alice")
    var object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(fixture.items[0].pr)) as? [String: Any])
    object["headRefOid"] = "reviewed-head"
    let pr = try JSONDecoder().decode(PullRequest.self, from: JSONSerialization.data(withJSONObject: object))
    let item = InboxItem(account: "alice", pr: pr, queues: [.authored])
    let transport = Actions(), client = GitHubClient(cli: transport)
    try await client.close(item)
    try await client.merge(item, method: .squash)
    let calls = await transport.calls
    #expect(calls[0].last == "alice" && calls[2].last == "alice")
    #expect(calls[1].contains("repos/example/tool/pulls/7") && calls[1].contains("state=closed") && calls[1].contains("PATCH"))
    #expect(calls[3].contains("repos/example/tool/pulls/7/merge") && calls[3].contains("sha=reviewed-head") && calls[3].contains("merge_method=squash"))
    await #expect(throws: CLIError.self) { try await client.merge(fixture.items[0], method: .merge) }
}

@Test func parsesGitHubPRLinksFromCommonViewsAndRejectsOtherTargets() throws {
    let link = try #require(PullRequestLink(" https://github.com/Example/repo/pull/123/files?diff=split#more "))
    #expect(link.nameWithOwner == "Example/repo" && link.number == 123)
    #expect(PullRequestLink("github.com/Example/repo/pull/123/") == link)
    for bad in ["https://github.com/example/repo/issues/1", "https://github.com.evil.test/o/r/pull/1",
                "https://github.com@other.test/o/r/pull/1", "https://other@github.com/o/r/pull/1",
                "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/x"] {
        #expect(PullRequestLink(bad) == nil)
    }
}
