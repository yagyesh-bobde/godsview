import Foundation

public struct AccountInbox: Sendable {
    public let items: [InboxItem]
    public let limited: Bool
}

public struct GitHubClient: Sendable {
    private let cli: any CommandRunning

    public init(cli: any CommandRunning = GitHubCLI()) { self.cli = cli }

    public func accounts() async throws -> [Account] {
        struct Status: Decodable { let hosts: [String: [Account]] }
        let data = try await cli.run(["auth", "status", "--json", "hosts"], token: nil, input: nil)
        return try JSONDecoder().decode(Status.self, from: data).hosts["github.com"] ?? []
    }

    public func inbox(for login: String) async throws -> AccountInbox {
        struct Page: Decodable {
            struct Info: Decodable { let hasNextPage: Bool }
            let nodes: [PullRequest]
            let pageInfo: Info
        }
        struct Searches: Decodable {
            let reviews: Page
            let authored: Page
            let assigned: Page
        }
        struct Response: Decodable { let data: Searches }

        let credential = try await token(for: login)
        let data = try await cli.run([
            "api", "graphql", "--hostname", "github.com",
            "-f", "query=" + Self.query,
            "-f", "reviews=is:pr is:open review-requested:\(login) sort:updated-desc",
            "-f", "authored=is:pr is:open author:\(login) sort:updated-desc",
            "-f", "assigned=is:pr is:open assignee:\(login) sort:updated-desc",
        ], token: credential, input: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pages = try decoder.decode(Response.self, from: data).data
        let groups: [(Queue, Page)] = [(.reviews, pages.reviews), (.authored, pages.authored), (.assigned, pages.assigned)]
        var items: [String: InboxItem] = [:]
        for (queue, page) in groups {
            for pr in page.nodes {
                items[pr.id, default: InboxItem(account: login, pr: pr, queues: [])].queues.insert(queue)
            }
        }
        return AccountInbox(items: Array(items.values), limited: groups.contains { $0.1.pageInfo.hasNextPage })
    }

    public func comment(_ body: String, on item: InboxItem) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("Write a comment before posting.")
        }
        let credential = try await token(for: item.account)
        let endpoint = "repos/\(item.pr.repository.nameWithOwner)/issues/\(item.pr.number)/comments"
        let payload = try JSONEncoder().encode(["body": body])
        _ = try await cli.run(["api", "--hostname", "github.com", "--method", "POST", endpoint, "--input", "-", "--silent"],
                              token: credential, input: payload)
    }

    private func token(for login: String) async throws -> String {
        let data = try await cli.run(["auth", "token", "--hostname", "github.com", "--user", login], token: nil, input: nil)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CLIError("Sign in again with gh auth login for @\(login).") }
        return value
    }

    private static let query = """
    query Inbox($reviews: String!, $authored: String!, $assigned: String!) {
      reviews: search(query: $reviews, type: ISSUE, first: 50) { ...Results }
      authored: search(query: $authored, type: ISSUE, first: 50) { ...Results }
      assigned: search(query: $assigned, type: ISSUE, first: 50) { ...Results }
    }
    fragment Results on SearchResultItemConnection {
      pageInfo { hasNextPage }
      nodes { ... on PullRequest {
        id number title url updatedAt isDraft reviewDecision headRefName baseRefName
        bodyText additions deletions changedFiles author { login } repository { nameWithOwner }
        labels(first: 8) { nodes { name } }
      } }
    }
    """
}
