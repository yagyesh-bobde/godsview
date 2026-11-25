import Foundation
import GitHubCore
import Observation

@MainActor @Observable
final class Workspace {
    let client: GitHubClient

    private let reviewCache: ReviewCache
    private let disk: WorkspaceDisk?
    private let preferences: UserDefaults?
    init(client: GitHubClient = GitHubClient(), disk: WorkspaceDisk? = nil, preferences: UserDefaults? = nil) {
        self.client = client
        self.disk = disk
        self.preferences = preferences
        reviewCache = ReviewCache(disk: disk)
        review = ReviewSession(cache: reviewCache)
        if let snapshot = disk?.inbox() {
            accounts = snapshot.accounts
            items = snapshot.items
            limited = snapshot.limited
            lastRefresh = snapshot.lastRefresh
            let previous = preferences?.string(forKey: "selectedPullRequest")
            selection = items.first { $0.id == previous }?.id ?? items.first?.id
            hasCheckedInbox = true
        }
    }
    var accounts: [Account] = []
    var items: [InboxItem] = []
    var queue: Queue = .inbox
    var scope: String?
    var query = ""
    var selection: String? {
        didSet {
            if selection != oldValue {
                review = ReviewSession(cache: reviewCache)
                preferences?.set(selection, forKey: "selectedPullRequest")
            }
        }
    }
    var review: ReviewSession
    var palette: PaletteMode?
    var systemSearchAvailable = false
    var focusTreeVisible = false
    var treeVisible: Bool { focusingFile ? focusTreeVisible : review.showTree }
    func toggleTree() {
        if focusingFile { focusTreeVisible.toggle() } else { review.showTree.toggle() }
    }
    var focusingFile = false
    var sidebarVisible = true
    var selected: InboxItem? { items.first { $0.id == selection } }

    func open(_ item: InboxItem) {
        scope = item.account
        queue = .inbox
        query = ""
        selection = item.id
    }

    var hasCheckedInbox = false
    var refreshing = false
    var lastRefresh: Date?
    var issues: [String: String] = [:]
    var limited: Set<String> = []
    var saved = Set(UserDefaults.standard.stringArray(forKey: "savedPullRequests") ?? [])

    var scoped: [InboxItem] { items.filter { scope == nil || $0.account == scope } }
    func includes(_ item: InboxItem, in queue: Queue) -> Bool {
        switch queue {
        case .inbox: true
        case .saved: saved.contains(item.id)
        default: item.queues.contains(queue)
        }
    }
    var visible: [InboxItem] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return scoped.filter { item in
            guard includes(item, in: queue) else { return false }
            guard !terms.isEmpty else { return true }
            let pr = item.pr
            let fields = [pr.title, pr.repository.nameWithOwner, "#\(pr.number)", pr.author?.login ?? "", item.account]
            return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(String(term)) } }
        }
    }

    func toggleSaved(_ item: InboxItem) {
        if !saved.insert(item.id).inserted { saved.remove(item.id) }
        UserDefaults.standard.set(saved.sorted(), forKey: "savedPullRequests")
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; hasCheckedInbox = true }
        do {
            let discovered = try await client.accounts()
            accounts = discovered.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
            let known = Set(accounts.map(\.login))
            if let scope, !known.contains(scope) { self.scope = nil }
            items.removeAll { !known.contains($0.account) }
            limited.formIntersection(known)
            issues = [:]
            var loads: [Task<Void, Never>] = []
            for account in accounts {
                guard account.state == "success" else {
                    issues[account.login] = "Run gh auth login to reconnect this account."
                    continue
                }
                loads.append(Task { await loadInbox(for: account.login) })
            }
            for load in loads { await load.value }
            if issues.isEmpty { lastRefresh = .now }
            if let disk {
                await disk.store(InboxSnapshot(accounts: accounts, items: items, limited: limited, lastRefresh: lastRefresh))
            }
        } catch {
            issues["GitHub CLI"] = error.localizedDescription
        }
    }

    private func loadInbox(for login: String) async {
        do {
            let inbox = try await client.inbox(for: login)
            items = (items.filter { $0.account != login } + inbox.items).sorted {
                if $0.pr.updatedAt == $1.pr.updatedAt { return $0.id < $1.id }
                return $0.pr.updatedAt > $1.pr.updatedAt
            }
            if selected?.account == login && (review.filesError != nil || review.commitsError != nil) { review.retry += 1 }
            if inbox.limited { limited.insert(login) } else { limited.remove(login) }
        } catch {
            issues[login] = error.localizedDescription
        }
    }
}
