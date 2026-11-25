import SwiftUI
import GitHubCore

struct T3ConversationView: View {
    let item: InboxItem
    let reviewRequest: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("t3MCPEnabled") private var enabled = false
    @State private var models: [T3Model] = []
    @State private var chosenModel: T3Model?
    @State private var project = ""
    @State private var question = ""
    @State private var threads: [T3ThreadRef] = []
    @State private var selected: String?
    @State private var conversation: T3Conversation?
    @State private var submitting = false
    @State private var error: String?
    @State private var refresh = 0
    private var historyKey: String { "t3Threads." + item.id }
    private var projectKey: String { "t3Project." + item.pr.repository.nameWithOwner.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(reviewRequest ? "PR review in T3" : "Ask T3").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
            }
            Text("\(item.pr.repository.nameWithOwner) #\(item.pr.number) · \(item.pr.title)")
                .lineLimit(2).foregroundStyle(Ink.dim)
            if !threads.isEmpty {
                DropdownField(title: "Conversation", value: threads.first { $0.id == selected }?.title ?? "New thread") {
                    [DropdownOption("New thread", icon: "plus.bubble", selected: selected == nil) { selected = nil }]
                        + threads.map { thread in
                            DropdownOption(thread.title, icon: "bubble.left", id: thread.id, selected: selected == thread.id) {
                                selected = thread.id
                            }
                        }
                }.disabled(submitting)
            }
            if selected == nil {
                HStack {
                    Text("T3 project").font(.callout)
                    Text(project.isEmpty ? "Select a project folder" : URL(fileURLWithPath: project).lastPathComponent)
                        .foregroundStyle(Ink.dim).help(project)
                    Spacer()
                    Button("Choose folder…") { chooseProject() }
                }
                DropdownField(title: "Model", value: chosenModel?.model ?? "T3 project default") {
                    [DropdownOption("T3 project default", icon: "folder", selected: chosenModel == nil) { chosenModel = nil }]
                        + models.map { model in
                            DropdownOption("\(model.model) · \(model.providerInstanceId)", icon: "cpu", selected: chosenModel == model) {
                                chosenModel = model
                            }
                        }
                }.disabled(submitting).help("Models recently used in this T3 project")
                    .task(id: project) {
                        models = []
                        chosenModel = nil
                        guard enabled, !project.isEmpty else { return }
                        do {
                            let found = try await T3MCP().recentModels(project: project)
                            if !Task.isCancelled { models = found }
                        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
            } else if let conversation {
                HStack {
                    Text([conversation.thread.model, conversation.thread.status.capitalized].compactMap { $0 }.joined(separator: " · "))
                    Spacer()
                    Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh conversation")
                    if let link = conversation.thread.link, let url = URL(string: link),
                       ["https", "http", "t3", "t3code"].contains(url.scheme) {
                        Link("Open in T3 ↗", destination: url)
                    }
                }.font(.caption).foregroundStyle(Ink.dim)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(conversation.messages.enumerated()), id: \.offset) { index, message in
                                let user = message.role == "user"
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(user ? item.account : "T3").font(.caption.bold()).foregroundStyle(user ? Ink.dim : Ink.purple)
                                    MarkdownBody(source: index == 0 && user ? initialQuestion(message.text) : message.text, url: item.pr.url)
                                }
                                Divider().id(index)
                            }
                        }.padding(12)
                    }.frame(minHeight: 130, maxHeight: 350).background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: conversation.messages.count, initial: true) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            } else { ProgressView("Reading thread…").controlSize(.small) }
            if let error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(Ink.red).textSelection(.enabled)
                    if selected != nil { Button("Refresh") { refresh += 1 } }
                }
            }
            let startingReview = reviewRequest && selected == nil
            if !startingReview {
                TextField(selected == nil ? "Ask about this PR…" : "Ask a follow-up…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6)
            }
            HStack {
                Spacer()
                Button(submitting ? "Sending…" : (startingReview ? "Start PR review" : "Send")) { submit(startingReview: startingReview) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!enabled || submitting || (selected == nil && project.isEmpty) ||
                              (!startingReview && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(22).frame(width: 570).background(Ink.detail).preferredColorScheme(.dark)
            .interactiveDismissDisabled(submitting)
            .onAppear {
                project = UserDefaults.standard.string(forKey: projectKey) ?? ""
                if let data = UserDefaults.standard.data(forKey: historyKey) {
                    threads = (try? JSONDecoder().decode([T3ThreadRef].self, from: data)) ?? []
                }
                if !reviewRequest { selected = threads.first?.id }
            }
            .task(id: "\(selected ?? "")/\(refresh)/\(enabled)") {
                guard enabled, let selected else { conversation = nil; return }
                do {
                    let client = try T3MCP()
                    repeat {
                        let next = try await client.read(selected)
                        try Task.checkCancellation()
                        conversation = next
                        error = nil
                        guard next.isWorking else { break }
                        try await Task.sleep(for: .seconds(4))
                    } while !Task.isCancelled
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .onChange(of: selected) { conversation = nil; error = nil }
    }

    private func initialQuestion(_ text: String) -> String {
        if let range = text.range(of: "\nQuestion:\n") { return String(text[range.upperBound...]) }
        return text.components(separatedBy: "\nPR: ").first ?? text
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use T3 project"
        if panel.runModal() == .OK, let url = panel.url {
            project = url.path
            UserDefaults.standard.set(project, forKey: projectKey)
        }
    }

    private func submit(startingReview: Bool) {
        guard enabled, !submitting else { return }
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            do {
                let client = try T3MCP()
                if let selected { try await client.send(question, thread: selected) }
                else {
                    let ref = try await client.start(item: item, project: project, question: startingReview ? nil : question,
                                                     model: chosenModel)
                    threads.insert(ref, at: 0)
                    UserDefaults.standard.set(try JSONEncoder().encode(threads), forKey: historyKey)
                    selected = ref.id
                }
                question = ""
                refresh += 1
            } catch { self.error = error.localizedDescription }
        }
    }
}
