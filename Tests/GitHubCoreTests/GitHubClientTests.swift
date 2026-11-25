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
