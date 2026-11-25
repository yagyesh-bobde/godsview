import SwiftUI
import GitHubCore

struct IntegrationSettings: View {
    @AppStorage("linearMCPEnabled") private var enabled = false
    @AppStorage("linearMCPEndpoint") private var endpoint = LinearMCP.defaultEndpoint
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Integrations") {
                Toggle("Linear MCP", isOn: $enabled)
                Text("Show issues referenced in a pull request’s title, branch, or description in Summary.")
                    .font(.callout).foregroundStyle(.secondary)
                if enabled {
                    TextField("MCP endpoint", text: $endpoint).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Test connection") { testing = true }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        if let status { Text(status).font(.caption).textSelection(.enabled) }
                    }
                }
            }
        }.formStyle(.grouped).frame(width: 480)
            .onChange(of: endpoint) { testing = false; status = nil }
            .onChange(of: enabled) { testing = false; status = nil }
            .task(id: testing) {
                guard testing else { return }
                do {
                    let session = try LinearMCP(endpoint: endpoint)
                    do { try await session.connect() }
                    catch { await session.close(); throw error }
                    await session.close()
                    if !Task.isCancelled { status = "Connected to Linear" }
                } catch { if !Task.isCancelled { status = error.localizedDescription } }
                if !Task.isCancelled { testing = false }
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
