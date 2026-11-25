import SwiftUI
import GitHubCore

@main
struct GodsViewApp: App {
    @State private var store = Workspace()
    @State private var showAccounts = false

    var body: some Scene {
        Window("GodsView", id: "workspace") {
            HStack(spacing: 0) {
                Sidebar(store: store, showAccounts: $showAccounts)
                Divider()
                InboxView(store: store, showAccounts: $showAccounts)
            }
            .frame(minWidth: 855, minHeight: 510)
            .foregroundStyle(Ink.text).tint(Ink.amber).preferredColorScheme(.dark)
            .sheet(isPresented: $showAccounts) { AccountSheet(store: store) }
            .task { if store.lastRefresh == nil { await store.refresh() } }
        }
        .defaultSize(width: 1170, height: 740)
        .commands {
            CommandMenu("Workspace") {
                Button("Filter Pull Requests") {
                    NotificationCenter.default.post(name: .focusInboxSearch, object: nil)
                }.keyboardShortcut("f")
                Button("Refresh Inbox") { Task { await store.refresh() } }
                    .keyboardShortcut("r").disabled(store.refreshing)
                Divider()
                Button("GitHub Accounts…") { showAccounts = true }
            }
        }
    }
}

private struct AccountSheet: View {
    let store: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private let command = "gh auth login --hostname github.com --web"

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("GitHub accounts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !store.accounts.isEmpty {
                ForEach(store.accounts) { account in
                    HStack {
                        Avatar(login: account.login)
                        Text(account.login)
                        Spacer()
                        if store.issues[account.login] != nil {
                            StatePill(text: "Needs attention", color: Ink.amber)
                        } else if account.active {
                            StatePill(text: "CLI default", color: Ink.green)
                        }
                    }
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Connect an account").font(.headline)
                Text("Run this command in Terminal, finish signing in, then refresh the inbox.").foregroundStyle(Ink.dim)
                HStack {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy sign-in command")
                }.padding(10).background(Ink.surface, in: RoundedRectangle(cornerRadius: 5))
            }
            if !store.issues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(store.issues.keys.sorted(), id: \.self) { key in
                            Text(key).font(.headline)
                            Text(store.issues[key] ?? "").font(.caption).foregroundStyle(Ink.dim).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 110)
            }
            HStack {
                Link("Get GitHub CLI", destination: URL(string: "https://cli.github.com")!)
                Spacer()
                Button(store.refreshing ? "Refreshing…" : "Refresh accounts") { Task { await store.refresh() } }.disabled(store.refreshing)
            }
        }.padding(24).frame(width: 460).preferredColorScheme(.dark)
    }
}
