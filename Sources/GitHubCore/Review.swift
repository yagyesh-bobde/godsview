import Foundation

public struct ChangedFile: Codable, Identifiable, Sendable, Hashable {
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

public struct ReviewLineRange: Equatable, Sendable {
    public enum Side: String, Sendable { case left = "LEFT", right = "RIGHT" }
    public let side: Side
    public let lines: ClosedRange<Int>

    public init?(side: Side, lines: ClosedRange<Int>) {
        guard lines.lowerBound > 0 else { return nil }
        self.side = side
        self.lines = lines
    }
}

extension GitHubClient {
    public func viewedFiles(on item: InboxItem) async throws -> [String: Bool] {
        struct File: Decodable { let path: String; let viewerViewedState: String }
        struct Files: Decodable { let nodes: [File] }
        struct Pull: Decodable { let files: Files }
        struct Payload: Decodable { let node: Pull }
        struct Page: Decodable { let data: Payload }
        let query = """
        query ViewedFiles($id: ID!, $endCursor: String) {
          node(id: $id) { ... on PullRequest {
            files(first: 100, after: $endCursor) {
              nodes { path viewerViewedState }
              pageInfo { hasNextPage endCursor }
            }
          } }
        }
        """
        let bytes = try await read(["graphql", "--paginate", "--slurp", "-f", "query=" + query,
                                    "-f", "id=" + item.pr.id], as: item.account)
        var result: [String: Bool] = [:]
        for page in try JSONDecoder().decode([Page].self, from: bytes) {
            for file in page.data.node.files.nodes { result[file.path] = file.viewerViewedState == "VIEWED" }
        }
        return result
    }

    public func setViewed(_ viewed: Bool, path: String, on item: InboxItem) async throws {
        let field = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        let query = """
        mutation FileViewed($id: ID!, $path: String!) {
          \(field)(input: {pullRequestId: $id, path: $path}) { clientMutationId }
        }
        """
        _ = try await read(["graphql", "-f", "query=" + query, "-f", "id=" + item.pr.id,
                            "-f", "path=" + path], as: item.account)
    }
}
