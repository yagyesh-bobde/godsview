import Foundation
import GitHubCore
import Observation

@MainActor @Observable
final class Workspace {
    let client: GitHubClient

    private let reviewCache: ReviewCache
    let disk: WorkspaceDisk?
    private let preferences: UserDefaults?
    init(client: GitHubClient = GitHubClient(), disk: WorkspaceDisk? = nil, preferences: UserDefaults? = nil) {
        self.client = client
        self.disk = disk
        self.preferences = preferences
        reviewCache = ReviewCache(disk: disk)
        review = ReviewSession(cache: reviewCache)
        hiddenRepositories = Set(preferences?.stringArray(forKey: "hiddenRepositories") ?? [])
        scope = preferences?.string(forKey: "workspaceAccountScope")
        if let snapshot = disk?.inbox() {
            accounts = snapshot.accounts
            items = snapshot.items
            linkedItem = snapshot.linkedItem
            limited = snapshot.limited
            lastRefresh = snapshot.lastRefresh
            let previous = preferences?.string(forKey: "selectedPullRequest")
            let candidates = scoped + [linkedRow].compactMap { $0 }
            selection = candidates.first { $0.id == previous }?.id ?? candidates.first?.id
            hasCheckedInbox = snapshot.lastRefresh != nil || !snapshot.items.isEmpty
        }
    }
    var accounts: [Account] = []
    var items: [InboxItem] = []
    var queue: Queue = .inbox
    var scope: String? {
        didSet { preferences?.set(scope, forKey: "workspaceAccountScope") }
    }
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
    var systemSearchLabel: String?
    var focusTreeVisible = false
    var treeVisible: Bool { focusingFile ? focusTreeVisible : review.showTree }
    func toggleTree() {
        if focusingFile { focusTreeVisible.toggle() } else { review.showTree.toggle() }
    }
    var focusingFile = false
    var sidebarWidth: CGFloat = 245
    var sidebarVisible = true
    private(set) var linkedItem: InboxItem?
    private(set) var hiddenRepositories: Set<String> = [] {
        didSet { preferences?.set(hiddenRepositories.sorted(), forKey: "hiddenRepositories") }
    }
    func hideRepository(_ name: String) {
        hiddenRepositories.insert(name.lowercased())
        if let selected, isHidden(selected) { selection = displayedIDs.first }
    }
    func showRepository(_ name: String) { hiddenRepositories.remove(name.lowercased()) }
    private func isHidden(_ item: InboxItem) -> Bool {
        hiddenRepositories.contains(item.pr.repository.nameWithOwner.lowercased())
    }

    var selected: InboxItem? {
        items.first { $0.id == selection } ?? (linkedItem?.id == selection ? linkedItem : nil)
    }
    var linkedRow: InboxItem? {
        guard let linkedItem, !isHidden(linkedItem), (scope == nil || scope == linkedItem.account), queue == .inbox, query.isEmpty,
              !items.contains(where: { $0.id == linkedItem.id }) else { return nil }
        return linkedItem
    }
    var displayedIDs: [String] { visible.map(\.id) + [linkedRow?.id].compactMap { $0 } }

    func launcherResults(_ text: String) -> [InboxItem] {
        let terms = text.split(whereSeparator: \.isWhitespace)
        let extra = linkedItem.flatMap { link in items.contains { $0.id == link.id } ? nil : link }
        return (items + [extra].compactMap { $0 }).filter { item in
            guard !isHidden(item) else { return false }
            let fields = [item.pr.title, "\(item.pr.repository.nameWithOwner)#\(item.pr.number)", item.account,
                          item.pr.author?.login ?? "", item.pr.headRefName]
            return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(String(term)) } }
        }
    }

    func resolve(_ link: PullRequestLink) async throws -> InboxItem {
        if hiddenRepositories.contains(link.nameWithOwner.lowercased()) {
            throw IntegrationError(message: "This repository is hidden. Show it in Settings to open its pull requests.")
        }
        let known = accounts.isEmpty ? try await client.accounts() : accounts
        let available = known.filter { $0.state == "success" }
        let preferred = scope ?? selected?.account ?? available.first(where: \.active)?.login
        let candidates = available.filter { $0.login == preferred } + available.filter { $0.login != preferred }
        guard !candidates.isEmpty else { throw IntegrationError(message: "Connect a GitHub account to open this link.") }
        let cached = launcherResults("").filter {
            $0.pr.number == link.number && $0.pr.repository.nameWithOwner.caseInsensitiveCompare(link.nameWithOwner) == .orderedSame
        }
        var errors: [String] = []
        for account in candidates {
            try Task.checkCancellation()
            if let hit = cached.first(where: { $0.account == account.login }) { return hit }
            do { return try await client.pullRequest(link, as: account.login) }
            catch { errors.append("@\(account.login): \(error.localizedDescription)") }
        }
        throw IntegrationError(message: errors.joined(separator: "\n"))
    }

    func openFromLauncher(_ item: InboxItem) {
        if !items.contains(where: { $0.id == item.id }) {
            linkedItem = item
            Task { await saveInbox() }
        }
        open(item)
    }

    func open(_ item: InboxItem) {
        guard !isHidden(item) else { return }
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

    var scoped: [InboxItem] { items.filter { !isHidden($0) && (scope == nil || $0.account == scope) } }
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

    private var removedPullRequests: [String: Date] = [:]

    func removeClosed(_ item: InboxItem) async {
        removedPullRequests[item.pr.id] = .now
        items.removeAll { $0.pr.id == item.pr.id }
        if linkedItem?.pr.id == item.pr.id { linkedItem = nil }
        if selected == nil { selection = visible.first?.id }
        await saveInbox()
    }

    @ObservationIgnored private var queuedSave: Task<Void, Never>?
    private func saveInbox() async {
        guard let disk else { return }
        let snapshot = InboxSnapshot(accounts: accounts, items: items, limited: limited, lastRefresh: lastRefresh, linkedItem: linkedItem)
        let previous = queuedSave
        let save = Task {
            await previous?.value
            await disk.store(snapshot)
        }
        queuedSave = save
        await save.value
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
            if let linkedItem, !known.contains(linkedItem.account) { self.linkedItem = nil }
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
            if let linkedItem, linkedItem.id == selection,
               let link = PullRequestLink(linkedItem.pr.url.absoluteString), !items.contains(where: { $0.id == linkedItem.id }),
               let updated = try? await client.pullRequest(link, as: linkedItem.account), self.linkedItem?.id == linkedItem.id {
                self.linkedItem = updated
            }
            if issues.isEmpty { lastRefresh = .now }
            await saveInbox()
        } catch {
            issues["GitHub CLI"] = error.localizedDescription
        }
    }

    private func loadInbox(for login: String) async {
        do {
            let inbox = try await client.inbox(for: login)
            let openItems = inbox.items.filter { item in
                guard let removed = removedPullRequests[item.pr.id] else { return true }
                return item.pr.updatedAt > removed
            }
            items = (items.filter { $0.account != login } + openItems).sorted {
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
