import Foundation

extension ChangedFile {
    public func withPatch(_ text: String) -> Self {
        Self(filename: filename, previousFilename: previousFilename, status: status, sha: sha,
             additions: additions, deletions: deletions, patch: text)
    }
}

extension GitHubClient {
    public func recoverPatch(for file: ChangedFile, on item: InboxItem, commit: String?) async throws -> String {
        let repo = "repos/" + item.pr.repository.nameWithOwner
        var before = ""
        if file.status != "added" {
            let revision: String?
            struct Ref: Decodable { let sha: String }
            if let commit {
                struct History: Decodable { let parents: [Ref] }
                let data = try await read(["\(repo)/git/commits/\(commit)"], as: item.account)
                revision = try JSONDecoder().decode(History.self, from: data).parents.first?.sha
            } else {
                guard let base = item.pr.baseRefOid, let head = item.pr.headRefOid else {
                    throw CLIError("Refresh the inbox to get the Git revisions for this pull request.")
                }
                struct Comparison: Decodable { let merge_base_commit: Ref }
                let data = try await read(["\(repo)/compare/\(base)...\(head)?per_page=1"], as: item.account)
                revision = try JSONDecoder().decode(Comparison.self, from: data).merge_base_commit.sha
            }
            if let revision {
                let path = file.previousFilename ?? file.filename
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
                guard let escaped = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw CLIError("Couldn’t read the previous file path.")
                }
                let data = try await read(["-H", "Accept: application/vnd.github.raw+json",
                                           "\(repo)/contents/\(escaped)?ref=\(revision)"], as: item.account)
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                    throw CLIError("The previous revision contains binary or non-UTF-8 data.")
                }
                before = text
            }
        }
        let after = file.status == "removed" ? "" : try await source(of: file, on: item)
        return try await Task.detached(priority: .userInitiated) { try unifiedPatch(before: before, after: after) }.value
    }
}

/// Use fixed local filenames so Git paths are never interpreted as command arguments.
func unifiedPatch(before: String, after: String) throws -> String {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appending(path: UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: folder) }
    try Data(before.utf8).write(to: folder.appending(path: "before"))
    try Data(after.utf8).write(to: folder.appending(path: "after"))
    let process = Process(), output = Pipe()
    process.currentDirectoryURL = folder
    process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    process.arguments = ["-u", "before", "after"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus == 0 { throw CLIError("The file contents are identical in both revisions.") }
    guard process.terminationStatus == 1, let diff = String(data: data, encoding: .utf8),
          let hunk = diff.range(of: "\n@@ ") else { throw CLIError("Couldn’t generate a text diff for these revisions.") }
    return String(diff[diff.index(after: hunk.lowerBound)...])
}
