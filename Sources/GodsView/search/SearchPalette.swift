import SwiftUI
import GitHubCore

private struct SearchHit: Identifiable {
    let id: String
    let group: String
    let icon: String
    let title: String
    let detail: String
    /// A short identifier that never truncates, such as a PR number.
    let badge: String?
    /// The full value shown on hover, such as a file's complete path.
    let help: String?
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
        func add(_ id: String, _ group: String, _ icon: String, _ title: String, _ detail: String, badge: String? = nil,
                 searchText: String? = nil, help: String? = nil, _ run: @escaping () -> Void) {
            // Match against everything the row stands for, not only what fits on screen.
            let candidate = (title + " " + detail + " " + (badge ?? "") + " " + (searchText ?? "")).lowercased()
            guard terms.allSatisfy({ candidate.contains($0) }) else { return }
            hits.append(SearchHit(id: id, group: group, icon: icon, title: title, detail: detail, badge: badge, help: help, run: run))
        }
        if mode == .global {
            // With no query, a short list of recent PRs leaves room to see the other groups.
            let items = store.launcherResults("")
            for item in query.isEmpty ? Array(items.prefix(5)) : items {
                // The owner is the same for most rows, so the short name is shown and the full
                // name stays searchable and in the tooltip.
                let repo = item.pr.repository.nameWithOwner
                let name = repo.split(separator: "/").last.map(String.init) ?? repo
                add(item.id, "Pull requests", "arrow.triangle.pull", item.pr.title,
                    "\(name) · \(item.account)", badge: "#\(item.pr.number)", searchText: repo,
                    help: "\(item.pr.repository.nameWithOwner) #\(item.pr.number) · \(item.account)") {
                    store.open(item)
                }
            }
        }
        if mode != .commits {
            for file in FileSearch.matches(review.files, query: query) {
                let name = (file.filename as NSString).lastPathComponent
                let folder = (file.filename as NSString).deletingLastPathComponent
                add("file/" + file.id, "Files", "doc.text", name, folder.isEmpty ? "/" : folder,
                    searchText: file.filename, help: file.filename) {
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
            add("refresh", "Commands", "arrow.clockwise", "Refresh inbox", "Sync GitHub accounts") { Task { await store.refresh() } }
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
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.dim)
                PaletteInput(text: $query, placeholder: title, fontSize: 15, move: { delta in
                    cursor = max(0, min(hits.count - 1, cursor + delta))
                }, submit: { if hits.indices.contains(cursor) { choose(hits[cursor]) } },
                             cancel: { store.palette = nil })
                Keycap("esc")
            }.padding(.horizontal, 18).frame(height: 52)
            WorkspaceRule()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            VStack(alignment: .leading, spacing: 0) {
                                if index == 0 || hits[index - 1].group != hit.group {
                                    PaletteGroupHeader(title: hit.group, first: index == 0)
                                }
                                Button { choose(hit) } label: {
                                    PaletteRow(icon: hit.icon, title: hit.title,
                                               detail: hit.group == "Commits" ? String(hit.detail.prefix(7)) : hit.detail,
                                               badge: hit.badge, selected: index == cursor, dense: true)
                                }.buttonStyle(.plain).help(hit.help ?? "")
                                    .onHover { if $0 { cursor = index } }
                            }.id(hit.id)
                        }
                        if hits.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(Ink.faint)
                                Text("No results for “\(query)”").foregroundStyle(Ink.dim)
                            }.font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        if mode == .files && store.review.filesLoading || mode == .commits && store.review.commitsLoading {
                            ProgressView().controlSize(.small).padding()
                        }
                        if let error = mode == .commits ? store.review.commitsError : (mode == .files ? store.review.filesError : nil) {
                            ReviewError(message: error) { store.review.retry += 1 }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.onChange(of: cursor) { _, index in if hits.indices.contains(index) { proxy.scrollTo(hits[index].id) } }
                    .onChange(of: query) { _, _ in cursor = 0; if let first = hits.first { proxy.scrollTo(first.id, anchor: .top) } }
            }.overlay(alignment: .bottom) { if hits.count > 9 { ScrollFade(color: Ink.rail) } }
            WorkspaceRule()
            PaletteFooter {
                HStack(spacing: 5) { Keycap("↑"); Keycap("↓"); Text("Navigate") }
                HStack(spacing: 5) { Keycap("↵"); Text("Open") }
                if mode == .global, let label = store.systemSearchLabel { HStack(spacing: 5) { Keycap(label); Text("PR launcher") } }
            } trailing: {
                Text(mode == .global ? "Workspace" : (mode == .commits ? "PR history" : "Changed files"))
            }
        }.frame(width: 660, height: 440)
            .background(Ink.rail, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            // The sheet shows this rounded surface instead of its own square backing.
            .presentationBackground(.clear)
    }

    private func choose(_ hit: SearchHit) {
        store.palette = nil
        hit.run()
    }
}

struct PaletteGroupHeader: View {
    let title: String
    var first = false
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.9).foregroundStyle(Ink.faint)
            .padding(.horizontal, 10).padding(.top, first ? 4 : 12).padding(.bottom, 5)
    }
}

/// A result row shared by the palette and the launcher: icon tile, title, detail, and a
/// Return hint on the highlighted row.
struct PaletteRow: View {
    let icon: String
    var iconTint: Color = Ink.dim
    let title: String
    var subtitle: String? = nil
    let detail: String
    var badge: String? = nil
    let selected: Bool
    /// Single-line palette rows; the launcher uses two lines with a subtitle.
    var dense = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let tile: CGFloat = dense ? 22 : 28
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: dense ? 11 : 12.5, weight: .medium))
                .foregroundStyle(selected ? Ink.text : iconTint)
                .frame(width: tile, height: tile)
                .background(Color.white.opacity(selected ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Ink.text : Ink.prose)
                if let subtitle {
                    Text(subtitle).lineLimit(1).truncationMode(.middle).font(.system(size: 11.5)).foregroundStyle(Ink.dim)
                }
            }.layoutPriority(1)
            Spacer(minLength: 12)
            if !detail.isEmpty {
                Text(detail).lineLimit(1).truncationMode(.middle).font(.system(size: 11.5)).foregroundStyle(Ink.faint)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
            if let badge {
                Text(badge).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Ink.dim)
                    .fixedSize()
            }
            // A fixed slot, so highlighting a row never changes how much of its title fits.
            Keycap("↵").opacity(selected ? 1 : 0).accessibilityHidden(true)
        }.padding(.horizontal, 7).frame(height: subtitle == nil ? 34 : 46)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .background {
                if selected { shape.fill(Color.white.opacity(0.07)).overlay(shape.strokeBorder(Color.white.opacity(0.08))) }
            }
            .contentShape(shape)
    }
}

/// A soft fade above the footer that tells the reader the list continues.
struct ScrollFade: View {
    let color: Color
    var body: some View {
        LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
            .frame(height: 22).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PaletteFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 16) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }.font(.system(size: 11.5)).foregroundStyle(Ink.dim).padding(.horizontal, 16).frame(height: 38)
    }
}

private final class PaletteTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A nonactivating panel can own the field editor while another app owns the menu bar.
        if window is NSPanel, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           let editor = currentEditor() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "a": editor.selectAll(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct PaletteInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = NSFont.systemFontSize
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        private var monitor: Any?

        func observeKeys(in field: NSTextField) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                // Only while the search field is editing, so a focused button still gets Return.
                guard let self, let field, let window = field.window, event.window === window,
                      (window.firstResponder as? NSTextView)?.delegate === field,
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
        let field = PaletteTextField()
        field.delegate = context.coordinator
        context.coordinator.observeKeys(in: field)
        field.font = .systemFont(ofSize: fontSize)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
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
