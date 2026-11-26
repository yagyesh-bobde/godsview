import AppKit
import SwiftUI

/// Where T3 Code stands for this Mac, shown in the toolbar and in Settings.
enum T3Status: Equatable {
    /// The `t3` command is not installed, so nothing can talk to T3.
    case notInstalled
    /// Installed, but the user has not turned T3 on in GodsView.
    case off
    case ready

    @MainActor static func current(enabled: Bool) -> T3Status {
        guard T3MCP.executable != nil else { return .notInstalled }
        return enabled ? .ready : .off
    }

    var title: String {
        switch self {
        case .notInstalled: "Not installed"
        case .off: "Off"
        case .ready: "On"
        }
    }

    var color: Color {
        switch self {
        case .notInstalled: Ink.red
        case .off: Ink.amber
        case .ready: Ink.green
        }
    }
}

/// The T3 project folder chosen for each repository, shared by Settings and the Ask sheet.
enum T3Projects {
    static func key(_ repository: String) -> String { "t3Project." + repository.lowercased() }
    static func folder(for repository: String) -> String? {
        UserDefaults.standard.string(forKey: key(repository)).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func set(_ folder: String?, for repository: String) {
        if let folder { UserDefaults.standard.set(folder, forKey: key(repository)) }
        else { UserDefaults.standard.removeObject(forKey: key(repository)) }
    }
    @MainActor static func choose(for repository: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use for \(repository)"
        panel.message = "Choose the local checkout T3 should open for \(repository)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        set(url.path, for: repository)
        return url.path
    }
}

/// The T3 section of Settings: a status line, a short checklist, and every repository's folder.
struct T3Settings: View {
    let store: Workspace
    @AppStorage("t3MCPEnabled") private var enabled = false
    @State private var status = T3Status.notInstalled
    @State private var executable: String?
    /// Bumped after a folder changes, so the list re-reads UserDefaults.
    @State private var folders = 0

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text("T3 Code is \(status.title.lowercased())").font(.headline)
                Spacer()
                Button("Check again") { refresh() }
            }
            .accessibilityElement(children: .combine)
            checklistRow(done: executable != nil, title: "t3 command installed",
                         detail: executable ?? "Open T3 Code, then install its command-line tool.")
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use T3 in GodsView")
                    Text("Ask questions and start reviews from the PR toolbar.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(executable == nil && !enabled)
        } header: {
            Text("T3 Code")
        }
        .onAppear(perform: refresh)
        .onChange(of: enabled) { _, _ in refresh() }

        Section("T3 project folders") {
            let repositories = Array(Set(store.items.map(\.pr.repository.nameWithOwner))).sorted()
            if repositories.isEmpty {
                Text("Repositories appear here once pull requests load.").foregroundStyle(.secondary)
            }
            ForEach(repositories, id: \.self) { repository in
                let folder = folders >= 0 ? T3Projects.folder(for: repository) : nil
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository).lineLimit(1).truncationMode(.middle)
                        Text(folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder yet")
                            .font(.caption).foregroundStyle(folder == nil ? Ink.amber : .secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Button(folder == nil ? "Choose…" : "Change…") {
                        if T3Projects.choose(for: repository) != nil { folders += 1 }
                    }
                    if folder != nil {
                        Button { T3Projects.set(nil, for: repository); folders += 1 } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Forget this folder").accessibilityLabel("Forget folder for \(repository)")
                    }
                }
            }
        }
    }

    private func checklistRow(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(done ? Ink.green : Ink.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        executable = T3MCP.executable?.path
        status = T3Status.current(enabled: enabled)
    }
}
