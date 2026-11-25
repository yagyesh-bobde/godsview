import Foundation

public struct Account: Decodable, Identifiable, Sendable, Hashable {
    public var id: String { login }
    public let login: String
    public let active: Bool
    public let state: String
}

public enum Queue: String, CaseIterable, Sendable {
    case inbox, reviews, authored, assigned, saved

    public var title: String {
        switch self {
        case .inbox: "All pull requests"
        case .reviews: "Review requests"
        case .authored: "Authored by me"
        case .assigned: "Assigned to me"
        case .saved: "Saved"
        }
    }
}

public struct PullRequest: Decodable, Identifiable, Sendable {
    public struct Repository: Decodable, Sendable { public let nameWithOwner: String }
    public struct Author: Decodable, Sendable { public let login: String }
    public struct Label: Decodable, Sendable { public let name: String }
    public struct Labels: Decodable, Sendable { public let nodes: [Label] }

    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: Repository
    public let author: Author?
    public let updatedAt: Date
    public let isDraft: Bool
    public let reviewDecision: String?
    public let headRefName: String
    public let baseRefName: String
    public let bodyText: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let labels: Labels
}

/// A pull request can be visible to several accounts with different permissions.
public struct InboxItem: Identifiable, Sendable {
    public var id: String { account + "/" + pr.id }
    public let account: String
    public let pr: PullRequest
    public var queues: Set<Queue>
}
