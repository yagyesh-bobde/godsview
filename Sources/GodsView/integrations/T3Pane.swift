import SwiftUI
import GitHubCore

/// What the toolbar or the diff asked the T3 column to do next.
enum T3PaneRequest: Equatable {
    /// Open with an optional question already typed, such as quoted diff lines.
    case ask(String?)
    /// Start a full review in a new conversation.
    case review
}

/// The T3 column beside the file tree. It follows T3 Code's chat: your messages in rounded
/// bubbles on the right, T3's replies as full-width text, and a rounded composer at the bottom.
struct T3Pane: View {
    let item: InboxItem
    @Bindable var review: ReviewSession
    /// Screenshot fixtures pass a conversation here instead of reading one from T3.
    var fixture: (thread: T3ThreadRef, conversation: T3Conversation)? = nil
    @AppStorage("t3MCPEnabled") private var enabled = false
    @State private var models: [T3Model] = []
    @State private var chosenModel: T3Model?
    @State private var project = ""
    @State private var draft = ""
    @State private var threads: [T3ThreadRef] = []
    @State private var selected: String?
    @State private var conversation: T3Conversation?
    @State private var submitting = false
    @State private var error: String?
    @State private var refresh = 0
    @FocusState private var composerFocused: Bool

    private var repository: String { item.pr.repository.nameWithOwner }
    private var historyKey: String { "t3Threads." + item.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkspaceRule()
            transcript
            composer
        }
        .background(Ink.rail)
        .onAppear {
            project = T3Projects.folder(for: repository) ?? ""
            if let data = UserDefaults.standard.data(forKey: historyKey) {
                threads = (try? JSONDecoder().decode([T3ThreadRef].self, from: data)) ?? []
            }
            selected = threads.first?.id
            if let fixture {
                threads = [fixture.thread]
                selected = fixture.thread.id
                conversation = fixture.conversation
                project = "/fixture/" + repository
            }
        }
        .onChange(of: review.t3Request, initial: true) { _, request in
            guard let request else { return }
            review.t3Request = nil
            switch request {
            case .ask(let text):
                if let text { draft = text }
                composerFocused = true
            case .review:
                selected = nil
                send(review: true)
            }
        }
        .task(id: "\(selected ?? "")/\(refresh)/\(enabled)") { await follow() }
        .task(id: project) { await loadModels() }
        .onChange(of: selected) { if fixture == nil { conversation = nil; error = nil } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.purple)
                .padding(.trailing, 2)
            Dropdown(width: 320, options: {
                [DropdownOption("New conversation", icon: "square.and.pencil", selected: selected == nil) { selected = nil }]
                    + threads.map { thread in
                        DropdownOption(thread.title, icon: "bubble.left", id: thread.id, selected: selected == thread.id) {
                            selected = thread.id
                        }
                    }
            }) {
                Text(threads.first { $0.id == selected }?.title ?? "New conversation")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            .disabled(submitting)
            .accessibilityLabel("Conversation")
            Spacer(minLength: 4)
            if let link = conversation?.thread.link, let url = URL(string: link),
               ["https", "http", "t3", "t3code"].contains(url.scheme) {
                Link(destination: url) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(IconButtonStyle()).help("Open in T3 Code").accessibilityLabel("Open in T3 Code")
            }
            toolIcon("square.and.pencil", "New conversation") { selected = nil; composerFocused = true }
                .disabled(selected == nil || submitting)
            toolIcon("xmark", "Close T3 panel") { review.t3Visible = false }
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: WorkspaceHeaderRow.controls.rawValue)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if fixture == nil && (!enabled || T3MCP.executable == nil) {
                        setupNotice
                    } else if project.isEmpty {
                        folderNotice
                    }
                    if selected == nil {
                        if enabled && !project.isEmpty { emptyState }
                    } else if let conversation {
                        ForEach(Array(conversation.messages.enumerated()), id: \.offset) { index, message in
                            if message.role == "user" {
                                userMessage(index == 0 ? Self.question(in: message.text) : message.text)
                            } else {
                                MarkdownBody(source: message.text, url: item.pr.url)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        status(conversation)
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading conversation…") }
                            .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    }
                    if let error {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.system(size: 12)).foregroundStyle(Ink.red).textSelection(.enabled)
                            Button("Try again") { self.error = nil; refresh += 1 }
                                .buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.small))
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
            }
            .onChange(of: conversation?.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation?.isWorking) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// T3 Code's user message: a soft rounded bubble on the right, at most 80% of the width.
    private func userMessage(_ text: String) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 64)
            Group {
                // Plain questions hug their text; quoted code keeps the full Markdown layout.
                if text.contains("```") { MarkdownBody(source: text, url: item.pr.url) }
                else {
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                        .font(.system(size: 13)).foregroundStyle(Ink.text).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: " + text)
    }

    @ViewBuilder private func status(_ conversation: T3Conversation) -> some View {
        if conversation.isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working…").font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
        } else {
            Text([conversation.thread.model, conversation.thread.status.capitalized].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Ink.faint)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask T3 about this PR").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                Text("T3 reads the diff and the code in \(URL(fileURLWithPath: project).lastPathComponent). Answers stay here; nothing is posted to GitHub.")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                suggestion("Review this pull request", icon: "text.magnifyingglass") { send(review: true) }
                suggestion("Summarize what changed", icon: "list.bullet") { draft = "Summarize what this pull request changes and why."; send() }
                suggestion("What should I test?", icon: "checklist") { draft = "What should I test before approving this pull request?"; send() }
            }
        }
    }

    private func suggestion(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.regular))
            .disabled(submitting)
    }

    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("T3 isn’t set up yet").font(.system(size: 13, weight: .semibold))
            Text(T3MCP.executable == nil ? "Install T3 Code’s t3 command, then turn T3 on in Settings."
                 : "Turn on T3 in Settings to ask questions here.")
                .font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Open Settings") }.buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.small))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var folderNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a folder for \(repository)").font(.system(size: 13, weight: .semibold))
            Text("T3 works in your local checkout of this repository.")
                .font(.system(size: 12)).foregroundStyle(Ink.dim)
            Button("Choose folder…") { if let folder = T3Projects.choose(for: repository) { project = folder } }
                .buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.small))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Composer

    private var canSend: Bool {
        enabled && !submitting && (selected != nil || !project.isEmpty)
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            TextField(selected == nil ? "Ask about this PR…" : "Ask a follow-up…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit { send() }
                .accessibilityLabel("Message T3")
            HStack(spacing: 6) {
                if selected == nil {
                    Dropdown(width: 300, edge: .top, options: {
                        [DropdownOption("Project default", icon: "folder", selected: chosenModel == nil) { chosenModel = nil }]
                            + models.map { model in
                                DropdownOption("\(model.model) · \(model.providerInstanceId)", icon: "cpu",
                                               selected: chosenModel == model) { chosenModel = model }
                            }
                    }) {
                        Text(chosenModel?.model ?? "Default model").font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Ink.dim).lineLimit(1)
                    }
                    .help("Models recently used in this T3 project")
                }
                Spacer(minLength: 4)
                Button { send() } label: {
                    Image(systemName: submitting ? "ellipsis" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(canSend ? Color.black : Ink.faint)
                        .background(canSend ? Ink.text : Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return). Option-Return adds a new line.").accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(Ink.field, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(composerFocused ? 0.18 : 0.1)))
        .padding(10)
    }

    // MARK: Data

    private func send(review startReview: Bool = false) {
        guard enabled, !submitting, selected != nil || !project.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard startReview || !text.isEmpty else { return }
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            do {
                let client = try T3MCP()
                if let selected, !startReview {
                    try await client.send(text, thread: selected)
                } else {
                    let ref = try await client.start(item: item, project: project, question: startReview ? nil : text,
                                                     model: chosenModel)
                    threads.insert(ref, at: 0)
                    UserDefaults.standard.set(try JSONEncoder().encode(threads), forKey: historyKey)
                    selected = ref.id
                }
                if !startReview { draft = "" }
                refresh += 1
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Reads the open conversation, and keeps reading every few seconds while T3 works.
    private func follow() async {
        guard fixture == nil else { return }
        guard enabled, let selected else { conversation = nil; return }
        do {
            let client = try T3MCP()
            repeat {
                let next = try await client.read(selected)
                try Task.checkCancellation()
                conversation = next
                error = nil
                guard next.isWorking else { break }
                try await Task.sleep(for: .seconds(3))
            } while !Task.isCancelled
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func loadModels() async {
        guard fixture == nil else { return }
        models = []
        chosenModel = nil
        guard enabled, !project.isEmpty else { return }
        do {
            let found = try await T3MCP().recentModels(project: project)
            if !Task.isCancelled { models = found }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    /// The first message carries the PR context for T3; only the question is shown.
    static func question(in text: String) -> String {
        if let range = text.range(of: "\nQuestion:\n") { return String(text[range.upperBound...]) }
        if text.hasPrefix("Review this pull request") { return "Review this pull request." }
        return text.components(separatedBy: "\nPR: ").first ?? text
    }
}

/// The T3 column with its own drag-to-resize edge. It stays mounted while hidden so a
/// conversation keeps its place, and opens and closes instantly like the sidebars.
struct T3Column: View {
    let store: Workspace
    let review: ReviewSession
    let item: InboxItem
    @State private var dragStart: CGFloat?

    var body: some View {
        let visible = review.t3Visible && !store.focusingFile
        let width = store.t3Width
        T3Pane(item: item, review: review)
            .frame(width: width).frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { edge }
            .frame(width: visible ? width : 0, alignment: .leading)
            .clipped().allowsHitTesting(visible).accessibilityHidden(!visible)
            .transaction { $0.animation = nil }
    }

    private var edge: some View {
        Color.clear.frame(width: 8)
            .overlay(alignment: .leading) { WorkspaceRule(vertical: true) }
            .contentShape(Rectangle())
            .onHover { over in if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? store.t3Width
                    dragStart = start
                    store.t3Width = max(300, min(620, start - drag.translation.width))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement().accessibilityLabel("T3 panel width")
            .accessibilityValue("\(Int(store.t3Width)) points")
            .accessibilityAdjustableAction { change in
                store.t3Width = max(300, min(620, store.t3Width + (change == .increment ? 20 : -20)))
            }
    }
}
