import SwiftUI
import GitHubCore

private struct SearchHit: Identifiable {
    let id: String
    let group: String
    let icon: String
    var tint = Ink.dim
    let title: String
    let detail: String
    /// A short identifier that never truncates, such as a PR number.
    let badge: String?
    /// A keyboard shortcut shown as keycaps.
    let shortcut: String?
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
    @State private var inputFocused = false
    /// The result group the palette is narrowed to; nil shows every group.
    @State private var scope: String?

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
                 shortcut: String? = nil, tint: Color = Ink.dim, searchText: String? = nil, help: String? = nil,
                 matched: Bool = false, _ run: @escaping () -> Void) {
            // Match against everything the row stands for, not only what fits on screen.
            let candidate = (title + " " + detail + " " + (badge ?? "") + " " + (searchText ?? "")).lowercased()
            guard matched || terms.allSatisfy({ candidate.contains($0) }) else { return }
            hits.append(SearchHit(id: id, group: group, icon: icon, tint: tint, title: title, detail: detail, badge: badge,
                                  shortcut: shortcut, help: help, run: run))
        }
        if mode == .global {
            // The same matcher as the PR launcher (title, repo#number, account, author, branch).
            // With no query, a short list of recent PRs leaves room to see the commands.
            let items = PRMatch.rankExact(store.launcherResults(query), query: query)
            for item in query.isEmpty && scope == nil ? Array(items.prefix(6)) : items {
                // The account is only worth showing when several are connected.
                let repo = item.pr.repository.nameWithOwner
                add(item.id, "Pull requests", item.pr.isDraft ? "pencil.circle" : "arrow.triangle.pull",
                    (item.pr.isDraft ? "Draft: " : "") + item.pr.title,
                    PRMatch.hiddenContext(item, query: query)
                        ?? (store.accounts.count > 1 ? "\(repo) · \(item.account)" : repo), badge: "#\(item.pr.number)",
                    tint: item.pr.isDraft ? Ink.faint : Ink.green,
                    help: "\(item.pr.repository.nameWithOwner) #\(item.pr.number) · \(item.account)", matched: true) {
                    store.open(item)
                }
            }
        }
        // Commands come right after pull requests so they are discoverable without a query.
        if mode == .global {
            add("refresh", "Commands", "arrow.clockwise", "Refresh inbox", "Sync GitHub accounts") { Task { await store.refresh() } }
            add("sidebar", "Commands", "sidebar.left", "Toggle sidebar", "", shortcut: "⌘ B") { store.sidebarVisible.toggle() }
            if store.selected != nil {
                add("focus", "Commands", "rectangle.center.inset.filled", store.codeFocused ? "Show sidebars" : "Focus on code",
                    "", shortcut: "⌥ ⌘ B") { review.tab = .code; store.toggleCodeFocus() }
            }
            if store.selected != nil {
                add("expand", "Commands", "arrow.up.left.and.arrow.down.right", "Toggle full-screen file view", "",
                    shortcut: "⇧ ⌘ ↩", toggleFullScreen)
                add("tree", "Commands", "sidebar.right", "Toggle changed files sidebar", "", shortcut: "⌘ L") {
                    review.tab = .code; store.toggleTree()
                }
            }
            for account in store.accounts {
                add("account/" + account.id, "Accounts", "person.crop.circle", account.login, "Show account inbox") {
                    store.scope = account.login
                    store.queue = .inbox
                    store.query = ""
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
        return Self.rankExact(hits, query: query)
    }

    private func scopeSections(_ all: [SearchHit]) -> [(name: String, count: Int)] {
        guard mode == .global else { return [] }
        var sections = groups(all)
        // The recent-PR list is trimmed when nothing is typed; the chip shows the full count.
        if query.isEmpty, let index = sections.firstIndex(where: { $0.name == "Pull requests" }) {
            sections[index].count = store.launcherResults("").count
        }
        // The active scope keeps its chip even when the query has no matches in it.
        if let scope, !sections.contains(where: { $0.name == scope }) { sections.append((scope, 0)) }
        return sections
    }

    /// Groups present for the current query, for the scope chips.
    private func groups(_ hits: [SearchHit]) -> [(name: String, count: Int)] {
        var order: [String] = [], counts: [String: Int] = [:]
        for hit in hits where hit.group != "Scope" {
            if counts[hit.group] == nil { order.append(hit.group) }
            counts[hit.group, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// Exact hits — a file name or path, a PR number, a commit SHA prefix, a title — move to the
    /// top so Return opens what was typed, even when other groups normally come first.
    private static func rankExact(_ hits: [SearchHit], query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return hits }
        func exact(_ hit: SearchHit) -> Bool {
            let title = hit.title.lowercased(), detail = hit.detail.lowercased()
            if title == q || (hit.help ?? "").lowercased() == q { return true }
            if let badge = hit.badge?.lowercased(), badge == q || badge == "#" + q { return true }
            if hit.group == "Commits", q.count >= 4, detail.hasPrefix(q) { return true }
            return false
        }
        // Keep each section contiguous: the section holding the first exact hit moves to the
        // top, and exact hits lead within their section.
        guard let lead = hits.first(where: exact)?.group else { return hits }
        var order: [String] = []
        for hit in hits where !order.contains(hit.group) { order.append(hit.group) }
        order.removeAll { $0 == lead }
        order.insert(lead, at: 0)
        return order.flatMap { group in
            let section = hits.filter { $0.group == group }
            return section.filter(exact) + section.filter { !exact($0) }
        }
    }

    var body: some View {
        let all = results
        let sections = scopeSections(all)
        let hits = scope.map { name in all.filter { $0.group == name } } ?? all
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(inputFocused ? Ink.blue : Ink.dim)
                PaletteInput(text: $query, placeholder: title, fontSize: 15, move: { delta in
                    cursor = max(0, min(hits.count - 1, cursor + delta))
                }, submit: { if hits.indices.contains(cursor) { choose(hits[cursor]) } },
                             cancel: { store.palette = nil }, focus: { inputFocused = $0 })
                Keycap("esc")
            }.padding(.horizontal, 18).frame(height: 52)
            SearchFocusRule(focused: inputFocused)
            if sections.count > 1 || scope != nil {
                // Every search scope is visible above the fold; a chip narrows the list to it.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ScopeChip(title: "All", count: nil, selected: scope == nil) { scope = nil; cursor = 0 }
                        ForEach(sections, id: \.name) { section in
                            ScopeChip(title: section.name, count: section.count, selected: scope == section.name) {
                                scope = scope == section.name ? nil : section.name
                                cursor = 0
                            }
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
                WorkspaceRule()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            VStack(alignment: .leading, spacing: 0) {
                                if index == 0 || hits[index - 1].group != hit.group {
                                    PaletteGroupHeader(title: hit.group, first: index == 0)
                                }
                                Button { choose(hit) } label: {
                                    PaletteRow(icon: hit.icon, iconTint: hit.tint, title: hit.title, highlight: query,
                                               detail: hit.group == "Commits" ? String(hit.detail.prefix(7)) : hit.detail,
                                               badge: hit.badge, shortcut: hit.shortcut, selected: index == cursor, dense: true)
                                }.buttonStyle(.plain).help(hit.help ?? "")
                                    .onHover { if $0 { cursor = index } }
                            }.id(hit.id)
                        }
                        if hits.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(Ink.faint)
                                Text(scope.map { "No \($0.lowercased()) match “\(query)”" } ?? "No results for “\(query)”")
                                    .foregroundStyle(Ink.dim)
                                if scope != nil {
                                    Button("Search everything") { scope = nil; cursor = 0 }.buttonStyle(.link)
                                }
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

struct ScopeChip: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count { Text("\(count)").monospacedDigit().foregroundStyle(selected ? Ink.text : Ink.faint) }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(selected ? Ink.text : Ink.dim)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color.white.opacity(selected ? 0.1 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Ink.blue.opacity(0.6) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel(count.map { "\(title), \($0) results" } ?? "All results")
            .accessibilityAddTraits(selected ? .isSelected : [])
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
    /// Query terms to emphasize in the title.
    var highlight = ""
    var subtitle: String? = nil
    let detail: String
    var badge: String? = nil
    var shortcut: String? = nil
    let selected: Bool
    /// Single-line palette rows; the launcher uses two lines with a subtitle.
    var dense = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let tile: CGFloat = dense ? 22 : 28
        HStack(spacing: 10) {
            // Colored icons (PR state) keep their color when the row is highlighted.
            Image(systemName: icon).font(.system(size: dense ? 11 : 12.5, weight: .medium))
                .foregroundStyle(selected && iconTint == Ink.dim ? Ink.text : iconTint)
                .frame(width: tile, height: tile)
                .background(Color.white.opacity(selected ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.emphasized(title, terms: highlight)).lineLimit(1).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Ink.text : Ink.prose)
                if let subtitle {
                    Text(subtitle).lineLimit(1).truncationMode(.middle).font(.system(size: 11.5)).foregroundStyle(Ink.dim)
                }
            }.layoutPriority(1)
            Spacer(minLength: 12)
            if !detail.isEmpty {
                Text(Self.emphasized(detail, terms: highlight)).lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 11.5)).foregroundStyle(Ink.faint)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            if let shortcut {
                HStack(spacing: 3) {
                    ForEach(Array(shortcut.split(separator: " ").enumerated()), id: \.offset) { Keycap(String($0.element)) }
                }.accessibilityLabel("Shortcut " + shortcut)
            }
            if let badge {
                Text(badge).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Ink.dim)
                    .fixedSize()
            }
            // A fixed slot, so highlighting a row never changes how much of its title fits.
            Keycap("↵").opacity(selected ? 1 : 0).accessibilityHidden(true)
        }.padding(.horizontal, 7).frame(height: subtitle == nil ? 34 : 46)
            // A leading accent bar marks the row Return will open.
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5).fill(Ink.blue).frame(width: 3, height: subtitle == nil ? 16 : 22)
                        .offset(x: -1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .background {
                if selected { shape.fill(Color.white.opacity(0.07)).overlay(shape.strokeBorder(Color.white.opacity(0.08))) }
            }
            .contentShape(shape)
    }
}

/// The line under a search field turns into an accent while the field has keyboard focus,
/// replacing the AppKit focus ring that does not fit the borderless field.
struct SearchFocusRule: View {
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            WorkspaceRule()
            Rectangle().fill(Ink.blue.opacity(0.75)).frame(height: 1.5).opacity(focused ? 1 : 0)
        }.frame(height: 1.5).animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
            .accessibilityHidden(true)
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

extension PaletteRow {
    /// Matched query terms are drawn in the accent color so the reason for a match is visible.
    static func emphasized(_ title: String, terms query: String) -> AttributedString {
        var result = AttributedString(title)
        for term in query.lowercased().split(whereSeparator: \.isWhitespace) {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: String(term), options: .caseInsensitive) {
                result[range].foregroundColor = Ink.blue
                searchStart = range.upperBound
            }
        }
        return result
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
    var focusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
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
    /// Reports when the field starts and stops editing, for a visible focus state.
    var focus: (Bool) -> Void = { _ in }

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
        func controlTextDidEndEditing(_ obj: Notification) { parent.focus(false) }
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
        field.focusChanged = { [weak coordinator = context.coordinator] focused in coordinator?.parent.focus(focused) }
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

enum PRMatch {
    /// Exact identifiers first (#123, 123, owner/repo#123, or the full title), then the rest in
    /// their original order, so Return opens the PR that was typed.
    static func rankExact(_ items: [InboxItem], query: String) -> [InboxItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        func exact(_ item: InboxItem) -> Bool {
            let pr = item.pr
            return q == "#\(pr.number)" || q == "\(pr.number)" || q == pr.title.lowercased()
                || q == "\(pr.repository.nameWithOwner)#\(pr.number)".lowercased()
        }
        return items.filter(exact) + items.filter { !exact($0) }
    }

    /// The PR matcher also searches the author and the source branch, which result rows do
    /// not show. When a query term only matched one of those, name it so the match is visible.
    static func hiddenContext(_ item: InboxItem, query: String) -> String? {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nil }
        let pr = item.pr
        let shown = [pr.title, "\(pr.repository.nameWithOwner)#\(pr.number)", item.account].joined(separator: " ").lowercased()
        let hidden = terms.filter { !shown.contains($0) }
        guard !hidden.isEmpty else { return nil }
        var parts: [String] = []
        if hidden.contains(where: pr.headRefName.lowercased().contains) { parts.append("branch " + pr.headRefName) }
        if let author = pr.author?.login, hidden.contains(where: author.lowercased().contains) { parts.append("by " + author) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
