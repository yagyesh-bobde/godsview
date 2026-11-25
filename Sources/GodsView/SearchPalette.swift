import SwiftUI
import GitHubCore

private struct SearchHit: Identifiable {
    let id: String
    let group: String
    let icon: String
    let title: String
    let detail: String
    let run: () -> Void
}

struct SearchPalette: View {
    let mode: PaletteMode
    @Bindable var store: Workspace
    let toggleFullScreen: () -> Void
    @State private var query = ""
    @State private var cursor = 0

    private var title: String {
        switch mode {
        case .global: "Search pull requests, files, commits, and commands…"
        case .files: "Open a changed file by name or path…"
        case .commits: "Find a commit by message or SHA…"
        }
    }
    private var results: [SearchHit] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let review = store.review
        var hits: [SearchHit] = []
        func add(_ id: String, _ group: String, _ icon: String, _ title: String, _ detail: String, _ run: @escaping () -> Void) {
            let candidate = (title + " " + detail).lowercased()
            guard terms.allSatisfy({ candidate.contains($0) }) else { return }
            hits.append(SearchHit(id: id, group: group, icon: icon, title: title, detail: detail, run: run))
        }
        if mode == .global {
            for item in store.items {
                add(item.id, "Pull requests", "arrow.triangle.branch", item.pr.title, "\(item.pr.repository.nameWithOwner) #\(item.pr.number) · \(item.account)") {
                    store.open(item)
                }
            }
        }
        if mode != .commits {
            for file in FileSearch.matches(review.files, query: query) {
                let name = (file.filename as NSString).lastPathComponent
                add("file/" + file.id, "Files", "doc.text", name, file.filename) {
                    review.tab = .code
                    review.filter = ""
                    review.reveal(file.filename)
                }
            }
        }
        if mode != .files {
            if mode == .commits { add("all", "Scope", "square.stack.3d.up", "All commits", "Whole pull request") { review.selectCommit(nil) } }
            for commit in review.commits.reversed() {
                add("commit/" + commit.id, "Commits", "point.topleft.down.to.point.bottomright.curvepath", commit.messageHeadline, commit.oid) {
                    review.selectCommit(commit.oid)
                }
            }
        }
        if mode == .global {
            add("refresh", "Commands", "arrow.clockwise", "Refresh inbox", "⌘R") { Task { await store.refresh() } }
            add("sidebar", "Commands", "sidebar.left", "Toggle sidebar", "⌘B") { store.sidebarVisible.toggle() }
            if store.selected != nil {
                add("expand", "Commands", "arrow.up.left.and.arrow.down.right", "Toggle full-screen file view", "⇧⌘Return", toggleFullScreen)
                add("tree", "Commands", "list.bullet.indent", "Toggle changed files sidebar", "⌘L") { review.tab = .code; store.toggleTree() }
            }
            for account in store.accounts {
                add("account/" + account.id, "Accounts", "person.crop.circle", account.login, "Show account inbox") {
                    store.scope = account.login
                    store.queue = .inbox
                    store.query = ""
                }
            }
        }
        return hits
    }

    var body: some View {
        let hits = results
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                PaletteInput(text: $query, placeholder: title, move: { delta in
                    cursor = max(0, min(hits.count - 1, cursor + delta))
                }, submit: { if hits.indices.contains(cursor) { choose(hits[cursor]) } },
                             cancel: { store.palette = nil })
                Text("esc").font(.caption.monospaced()).foregroundStyle(Ink.faint)
            }.padding(.horizontal, 16).frame(height: 47)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || hits[index - 1].group != hit.group {
                                Text(hit.group).font(.caption.weight(.medium)).foregroundStyle(Ink.faint)
                                    .padding(.horizontal, 7).padding(.top, 8).padding(.bottom, 3)
                            }
                            Button { choose(hit) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: hit.icon).frame(width: 16).foregroundStyle(Ink.dim)
                                    Text(hit.title).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(hit.group == "Commits" ? String(hit.detail.prefix(7)) : hit.detail)
                                        .lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(Ink.faint)
                                }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 30)
                                    .background(index == cursor ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            }.id(hit.id)
                        }
                        if hits.isEmpty { Text("No results").foregroundStyle(Ink.dim).padding() }
                        if mode == .files && store.review.filesLoading || mode == .commits && store.review.commitsLoading {
                            ProgressView().controlSize(.small).padding()
                        }
                        if let error = mode == .commits ? store.review.commitsError : (mode == .files ? store.review.filesError : nil) {
                            ReviewError(message: error) { store.review.retry += 1 }
                        }
                    }.padding(6)
                }.onChange(of: cursor) { _, index in if hits.indices.contains(index) { proxy.scrollTo(hits[index].id) } }
                    .onChange(of: query) { _, _ in cursor = 0; if let first = hits.first { proxy.scrollTo(first.id, anchor: .top) } }
            }
            Divider()
            HStack(spacing: 12) {
                Text("↑ ↓  Navigate")
                Text("↵  Open")
                if mode == .global && store.systemSearchAvailable { Text("⌃⌥K  From any app") }
                Spacer()
                Text(mode == .global ? "Workspace" : (mode == .commits ? "PR history" : "Changed files"))
            }.font(.caption).foregroundStyle(Ink.faint).padding(.horizontal, 13).frame(height: 28)
        }.frame(width: 610, height: 392).background(Ink.rail)
    }

    private func choose(_ hit: SearchHit) {
        store.palette = nil
        hit.run()
    }
}

private struct PaletteInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        private var monitor: Any?

        func observeKeys(in field: NSTextField) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                guard let self, let window = field?.window, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                switch event.keyCode {
                case 125: parent.move(1)
                case 126: parent.move(-1)
                case 36, 76: parent.submit()
                case 53: parent.cancel()
                default: return event
                }
                return nil
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        var parent: PaletteInput
        init(_ parent: PaletteInput) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        context.coordinator.observeKeys(in: field)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.stopObserving()
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}

enum FileSearch {
    static func matches(_ files: [ChangedFile], query: String) -> [ChangedFile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return files }
        let words = term.split(whereSeparator: \.isWhitespace)
        return files.compactMap { file -> (Int, ChangedFile)? in
            let path = file.filename.lowercased()
            guard words.allSatisfy({ path.contains($0) }) else { return nil }
            let name = (path as NSString).lastPathComponent
            let score: Int
            if name == term || path == term { score = 0 }
            else if (name as NSString).deletingPathExtension == term { score = 1 }
            else if name.hasPrefix(term) { score = 2 }
            else if name.contains(term) { score = 3 }
            else { score = 4 }
            return (score, file)
        }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.filename < $1.1.filename }.map(\.1)
    }
}
