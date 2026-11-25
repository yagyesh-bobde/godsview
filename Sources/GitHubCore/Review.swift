import Foundation

public struct ChangedFile: Decodable, Identifiable, Sendable, Hashable {
    public var id: String { filename }
    public let filename: String
    public let previousFilename: String?
    public let status: String
    public let sha: String
    public let additions: Int
    public let deletions: Int
    public let patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, sha, additions, deletions, patch
        case previousFilename = "previous_filename"
    }
}

public struct ReviewCommit: Decodable, Identifiable, Sendable, Hashable {
    public var id: String { oid }
    public let oid: String
    public let messageHeadline: String
    public var shortID: String { String(oid.prefix(7)) }
}

extension GitHubClient {
    public func files(on item: InboxItem, commit: String? = nil) async throws -> [ChangedFile] {
        let repo = "repos/" + item.pr.repository.nameWithOwner
        let endpoint = commit.map { "\(repo)/commits/\($0)" } ?? "\(repo)/pulls/\(item.pr.number)/files"
        let data = try await read(["--paginate", "--slurp", endpoint + "?per_page=100"], as: item.account)
        let decoder = JSONDecoder()
        if commit != nil {
            struct Page: Decodable { let files: [ChangedFile] }
            return try decoder.decode([Page].self, from: data).flatMap(\.files)
        }
        return try decoder.decode([[ChangedFile]].self, from: data).flatMap { $0 }
    }

    public func commits(on item: InboxItem) async throws -> [ReviewCommit] {
        struct Entry: Decodable { let commit: ReviewCommit }
        struct Connection: Decodable { let nodes: [Entry] }
        struct Pull: Decodable { let commits: Connection }
        struct Payload: Decodable { let node: Pull }
        struct Page: Decodable { let data: Payload }
        let query = """
        query History($id: ID!, $endCursor: String) {
          node(id: $id) { ... on PullRequest {
            commits(first: 100, after: $endCursor) {
              nodes { commit { oid messageHeadline } }
              pageInfo { hasNextPage endCursor }
            }
          } }
        }
        """
        let data = try await read(["graphql", "--paginate", "--slurp", "-f", "query=" + query,
                                   "-f", "id=" + item.pr.id], as: item.account)
        return try JSONDecoder().decode([Page].self, from: data).flatMap { $0.data.node.commits.nodes.map(\.commit) }
    }

    public func source(of file: ChangedFile, on item: InboxItem) async throws -> String {
        let endpoint = "repos/\(item.pr.repository.nameWithOwner)/git/blobs/\(file.sha)"
        let data = try await read(["-H", "Accept: application/vnd.github.raw+json", endpoint], as: item.account)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw CLIError("This blob contains binary or non-UTF-8 data.")
        }
        return text
    }
}
