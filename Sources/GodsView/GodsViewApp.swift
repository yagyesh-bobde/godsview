import SwiftUI
import GitHubCore

@main
struct GodsViewApp: App {
    @State private var store = Workspace()
    @State private var showAccounts = false

    @State private var controls = WindowControls()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("GodsView", id: "workspace") {
            InboxView(store: store, showAccounts: $showAccounts, controls: controls)
                .frame(minWidth: 855, minHeight: 510)
                .foregroundStyle(Ink.text).tint(Ink.blue).preferredColorScheme(.dark)
                .background(WindowReader(controls: controls))
                .sheet(isPresented: $showAccounts) { AccountSheet(store: store) }
                .sheet(item: $store.palette) { mode in
                    SearchPalette(mode: mode, store: store) { controls.toggleFileFocus(store) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                    if note.object as? NSWindow === controls.window { store.focusingFile = false }
                }
                .onAppear {
                    store.systemSearchAvailable = controls.registerSearchShortcut {
                        openWindow(id: "workspace")
                        NSApp.activate(ignoringOtherApps: true)
                        controls.window?.makeKeyAndOrderFront(nil)
                        if controls.window?.attachedSheet == nil { store.palette = .global }
                    }
                }
                .task { if store.lastRefresh == nil { await store.refresh() } }
        }
        .defaultSize(width: 1330, height: 810)
        .commands {
            CommandMenu("Workspace") {
                Button("Search Workspace…") { store.palette = .global }.keyboardShortcut("k")
                Button("Global Search…") { store.palette = .global }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Open Changed File…") { store.palette = .files }.keyboardShortcut("p").disabled(store.selected == nil)
                Button("Choose Commit…") { store.palette = .commits }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.selected == nil)
                Button("Find in File…") {
                    store.review.tab = .code
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .findReviewText, object: nil) }
                }.keyboardShortcut("f").disabled(store.review.selectedFile == nil)
                Divider()
                Button("Toggle Changed Files Sidebar") { store.review.tab = .code; store.toggleTree() }
                    .keyboardShortcut("l").disabled(store.selected == nil)
                Button("Toggle Sidebar") { store.sidebarVisible.toggle() }.keyboardShortcut("b").disabled(store.focusingFile)
                Button("Full-Screen File View") { controls.toggleFileFocus(store) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(store.selected == nil)
                Button("Previous Changed File") { stepFile(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(store.review.adjacentFile(-1) == nil)
                Button("Next Changed File") { stepFile(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(store.review.adjacentFile(1) == nil)
                Button("Previous Commit") { stepCommit(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(store.review.adjacentCommit(-1) == nil)
                Button("Next Commit") { stepCommit(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(store.review.adjacentCommit(1) == nil)
                Divider()
                Button("Refresh Inbox") { Task { await store.refresh() } }.keyboardShortcut("r").disabled(store.refreshing)
                Button("GitHub Accounts…") { showAccounts = true }
            }
        }
    }

    private func stepFile(_ direction: Int) {
        if let file = store.review.adjacentFile(direction) {
            store.review.tab = .code
            store.review.filter = ""
            store.review.path = file.filename
        }
    }

    private func stepCommit(_ direction: Int) {
        if let commit = store.review.adjacentCommit(direction) { store.review.selectCommit(commit.oid) }
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
                            StatePill(text: "Needs attention", color: Ink.blue)
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
