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

    public func discussion(on item: InboxItem) async throws -> [DiscussionComment] {
        struct Comments: Decodable { let nodes: [DiscussionComment] }
        struct Node: Decodable { let comments: Comments }
        struct Payload: Decodable { let node: Node }
        struct Response: Decodable { let data: Payload }
        let query = """
        query Conversation($id: ID!) {
          node(id: $id) { ... on PullRequest {
            comments(last: 20) { nodes { id author { login } createdAt body bodyText } }
          } }
        }
        """
        let credential = try await token(for: item.account)
        let data = try await cli.run(["api", "graphql", "--hostname", "github.com", "-f", "query=" + query,
                                      "-f", "id=" + item.pr.id], token: credential, input: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).data.node.comments.nodes
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

    func read(_ arguments: [String], as login: String) async throws -> Data {
        let credential = try await token(for: login)
        try Task.checkCancellation()
        return try await cli.run(["api", "--hostname", "github.com"] + arguments, token: credential, input: nil)
    }

    private func token(for login: String) async throws -> String {
        let data = try await cli.run(["auth", "token", "--hostname", "github.com", "--user", login], token: nil, input: nil)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CLIError("Sign in again with gh auth login for @\(login).") }
        return value
    }

    private static let prFields = """
        id number title url updatedAt state isDraft reviewDecision headRefName baseRefName headRefOid baseRefOid
        body bodyText additions deletions changedFiles author { login } repository { nameWithOwner }
        labels(first: 8) { nodes { name } }
        """

    public func pullRequest(_ link: PullRequestLink, as account: String) async throws -> InboxItem {
        struct Repo: Decodable { let pullRequest: PullRequest? }
        struct Payload: Decodable { let repository: Repo? }
        struct Result: Decodable { let data: Payload }
        let query = """
        query LinkedPR($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) { pullRequest(number: $number) { \(Self.prFields) } }
        }
        """
        let bytes = try await read(["graphql", "-f", "query=" + query, "-f", "owner=" + link.owner,
                                    "-f", "repo=" + link.repository, "-F", "number=\(link.number)"], as: account)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pr = try decoder.decode(Result.self, from: bytes).data.repository?.pullRequest else {
            throw CLIError("Pull request unavailable for @\(account).")
        }
        return InboxItem(account: account, pr: pr, queues: [])
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
        \(prFields)
      } }
    }
    """
}

public enum MergeMethod: String, CaseIterable, Sendable {
    case merge, squash, rebase

    public var title: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}

extension GitHubClient {
    public func close(_ item: InboxItem) async throws {
        struct Result: Decodable { let state: String }
        let endpoint = "repos/\(item.pr.repository.nameWithOwner)/pulls/\(item.pr.number)"
        let bytes = try await read(["--method", "PATCH", endpoint, "-f", "state=closed"], as: item.account)
        guard try JSONDecoder().decode(Result.self, from: bytes).state == "closed" else {
            throw CLIError("GitHub did not confirm that this pull request was closed.")
        }
    }

    public func merge(_ item: InboxItem, method: MergeMethod) async throws {
        struct Result: Decodable { let merged: Bool; let message: String? }
        guard let head = item.pr.headRefOid, !head.isEmpty else { throw CLIError("Refresh the inbox to load the PR head before merging.") }
        let endpoint = "repos/\(item.pr.repository.nameWithOwner)/pulls/\(item.pr.number)/merge"
        let bytes = try await read(["--method", "PUT", endpoint, "-f", "sha=" + head,
                                    "-f", "merge_method=" + method.rawValue], as: item.account)
        let result = try JSONDecoder().decode(Result.self, from: bytes)
        guard result.merged else { throw CLIError(result.message ?? "GitHub declined this merge.") }
    }
}
