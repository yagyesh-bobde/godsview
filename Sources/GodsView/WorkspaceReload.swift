import AppKit
import GitHubCore

/// Only navigation crosses between app instances. PR data comes from the normal cache and refresh.
struct WorkspaceNavigation: Codable {
    let selection: String?
    let queue: Queue
    let scope: String?
    let query: String
    let tab: ReviewTab
    let commit: String?
    let path: String?
    let mode: FileMode
    let singleFile: Bool
    let tree: Bool
    let sidebar: Bool
    let filter: String
    let folded: Set<String>
    let headerCollapsed: Bool
    let automaticallyFoldHeader: Bool

    @MainActor init(_ store: Workspace) {
        selection = store.selection
        queue = store.queue
        scope = store.scope
        query = store.query
        sidebar = store.sidebarVisible
        let review = store.review
        tab = review.tab
        commit = review.commit
        path = review.path
        mode = review.mode
        singleFile = review.singleFile || store.focusingFile
        tree = store.treeVisible
        filter = review.filter
        folded = review.collapsedFiles
        headerCollapsed = review.headerCollapsed
        automaticallyFoldHeader = review.automaticallyFoldHeader
    }

    @MainActor func restore(in store: Workspace) {
        store.scope = scope  // Account discovery validates the restored login, even on a cold launch.
        store.queue = queue
        store.query = query
        store.sidebarVisible = sidebar
        guard let selection, store.displayedIDs.contains(selection) else {
            store.selection = store.visible.first?.id
            return
        }
        store.selection = selection
        let review = store.review
        review.tab = tab
        review.commit = commit
        review.path = path
        review.mode = mode
        review.singleFile = singleFile
        review.showTree = tree
        review.filter = filter
        review.collapsedFiles = folded
        review.headerCollapsed = headerCollapsed
        review.automaticallyFoldHeader = automaticallyFoldHeader
    }
}

@MainActor
enum WorkspaceReload {
    private static let argument = "--restore-workspace"
    private static let key = "workspaceNavigationForReload"

    static func restoreIfRequested(_ store: Workspace) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let state = try? JSONDecoder().decode(WorkspaceNavigation.self, from: data) {
            state.restore(in: store)
        }
        defaults.removeObject(forKey: key)
    }

    static func relaunch(_ store: Workspace) async throws {
        let defaults = UserDefaults.standard
        defaults.set(try JSONEncoder().encode(WorkspaceNavigation(store)), forKey: key)
        // The replacement process reads this immediately, before the regular defaults flush.
        defaults.synchronize()
        do {
            let bundle = Bundle.main
            if bundle.bundleURL.pathExtension == "app" {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = NSApp.isActive
                config.hides = NSApp.isHidden
                config.createsNewApplicationInstance = true
                config.arguments = [argument]
                let app = try await NSWorkspace.shared.openApplication(at: bundle.bundleURL, configuration: config)
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw CocoaError(.executableLoad) }
            } else {
                guard let executable = bundle.executableURL else { throw CocoaError(.executableNotLoadable) }
                try Process.run(executable, arguments: [argument])
            }
        } catch {
            defaults.removeObject(forKey: key)
            throw error
        }
        NSApp.terminate(nil)
    }
}
