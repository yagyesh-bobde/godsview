import SwiftUI
import GitHubCore

struct IntegrationSettings: View {
    let shortcut: LauncherShortcut
    @AppStorage("linearMCPEnabled") private var enabled = false
    @AppStorage("linearMCPEndpoint") private var endpoint = LinearMCP.defaultEndpoint
    @AppStorage("t3MCPEnabled") private var t3Enabled = false
    @State private var t3Installed = false
    @State private var status: String?
    @State private var testing = false
    @State private var probes = 0

    var body: some View {
        Form {
            ShortcutSettings(shortcut: shortcut)
            Section("Linear") {
                Toggle("Linear MCP", isOn: $enabled)
                Text("Show issues referenced in a pull request’s title, branch, or description in Summary.")
                    .font(.callout).foregroundStyle(.secondary)
                if enabled {
                    TextField("MCP endpoint", text: $endpoint).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Check connection") { probes += 1 }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let status { Text(status).font(.caption).textSelection(.enabled) }
                }
            }
            Section("T3 Code") {
                Toggle("T3 Code MCP", isOn: $t3Enabled).disabled(!t3Installed && !t3Enabled)
                Text(t3Installed ? "T3 detected. Ask questions and start reviews from the PR toolbar." : "Open T3 Code and install its t3 command to connect.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 500, height: 445)
            .onAppear { t3Installed = T3MCP.executable != nil }
            .task(id: [endpoint, String(probes), String(enabled)]) {
                status = nil
                testing = true
                defer { if !Task.isCancelled { testing = false } }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let session = try LinearMCP(endpoint: endpoint)
                    do { try await session.connect() }
                    catch { await session.close(); throw error }
                    await session.close()
                    if !Task.isCancelled { status = "Linear MCP detected" }
                } catch { if !Task.isCancelled { status = error.localizedDescription } }
            }
    }
}

struct LinkedIssuesView: View {
    let pr: PullRequest
    @AppStorage("linearMCPEnabled") private var enabled = false
    @AppStorage("linearMCPEndpoint") private var endpoint = LinearMCP.defaultEndpoint
    @State private var issues: [LinearIssue] = []
    @State private var problem: String?
    @State private var loading = true
    @State private var retry = 0

    var body: some View {
        if enabled {
            let ids = LinearIssue.references(in: [pr.title, pr.headRefName, pr.body ?? pr.bodyText].joined(separator: "\n"))
            if !ids.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Linear issues", systemImage: "link").font(.headline)
                    if loading { ProgressView().controlSize(.small) }
                    ForEach(issues) { issue in
                        Link(destination: issue.url) {
                            HStack(spacing: 8) {
                                Text(issue.id).font(.caption.monospaced()).foregroundStyle(Ink.purple)
                                Text(issue.title).lineLimit(2).foregroundStyle(Ink.text)
                                Spacer()
                                if let status = issue.status { StatePill(text: status, color: Ink.dim) }
                                Image(systemName: "arrow.up.right").font(.caption2)
                            }.padding(10).background(Ink.surface, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                    if let problem {
                        HStack { Text(problem); Button("Retry") { retry += 1 } }.font(.caption).foregroundStyle(Ink.dim)
                    }
                }.task(id: [endpoint, String(retry)] + ids) {
                    loading = true
                    problem = nil
                    do {
                        let result = try await LinkedIssueCache.shared.lookup(ids, endpoint: endpoint)
                        guard !Task.isCancelled else { return }
                        issues = result.issues
                        if !result.missing.isEmpty { problem = "Couldn’t read " + result.missing.joined(separator: ", ") }
                    } catch { if !Task.isCancelled { problem = error.localizedDescription } }
                    if !Task.isCancelled { loading = false }
                }
            }
        }
    }
}
