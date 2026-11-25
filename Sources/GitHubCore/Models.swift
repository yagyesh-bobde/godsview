import Foundation

public struct Account: Codable, Identifiable, Sendable, Hashable {
    public var id: String { login }
    public let login: String
    public let active: Bool
    public let state: String
}

public enum Queue: String, Codable, CaseIterable, Sendable {
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

public struct PullRequest: Codable, Identifiable, Sendable {
    public struct Repository: Codable, Sendable { public let nameWithOwner: String }
    public struct Author: Codable, Sendable { public let login: String }
    public struct Label: Codable, Sendable { public let name: String }
    public struct Labels: Codable, Sendable { public let nodes: [Label] }

    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: Repository
    public let author: Author?
    public let updatedAt: Date
    public let state: String?
    public var isOpen: Bool { state == nil || state == "OPEN" }
    public var stateLabel: String {
        if state == "MERGED" { return "Merged" }
        if state == "CLOSED" { return "Closed" }
        return isDraft ? "Draft" : "Open"
    }
    public let isDraft: Bool
    public let reviewDecision: String?
    public let headRefOid: String?
    public let baseRefOid: String?
    public var diffRevision: String {
        if let headRefOid, let baseRefOid { return baseRefOid + "..." + headRefOid }
        return String(updatedAt.timeIntervalSinceReferenceDate)
    }
    public let headRefName: String
    public let baseRefName: String
    public let body: String?
    public let bodyText: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let labels: Labels
}

/// A pull request can be visible to several accounts with different permissions.
public struct InboxItem: Codable, Identifiable, Sendable {
    public var id: String { account + "/" + pr.id }
    public let account: String
    public let pr: PullRequest
    public var queues: Set<Queue>
}

public struct DiscussionComment: Codable, Identifiable, Sendable {
    public let id: String
    public let author: PullRequest.Author?
    public let createdAt: Date
    public let body: String?
    public let bodyText: String
}
