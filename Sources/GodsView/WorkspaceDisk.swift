import Foundation
import CryptoKit
import GitHubCore

struct InboxSnapshot: Codable, Sendable {
    let accounts: [Account]
    let items: [InboxItem]
    let limited: Set<String>
    let lastRefresh: Date?
}

struct WorkspaceDisk: Sendable {
    let directory: URL
    static let standard = Self(directory: URL.cachesDirectory
        .appending(path: "io.github.yagyesh-bobde.godsview/v1"))

    func inbox() -> InboxSnapshot? {
        guard let data = try? Data(contentsOf: directory.appending(path: "inbox.json")) else { return nil }
        return try? JSONDecoder().decode(InboxSnapshot.self, from: data)
    }

    func store(_ snapshot: InboxSnapshot) async {
        do { try write(JSONEncoder().encode(snapshot), in: directory, name: "inbox.json") }
        catch { NSLog("GodsView could not save the inbox cache (%ld).", (error as NSError).code) }
    }

    private func write(_ data: Data, in folder: URL, name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: name)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func reviewFile(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "reviews/" + digest)
    }

    func files(for key: String) -> [ChangedFile]? {
        let url = reviewFile(key)
        guard let data = try? Data(contentsOf: url),
              let files = try? JSONDecoder().decode([ChangedFile].self, from: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return files
    }

    func store(_ files: [ChangedFile], for key: String) {
        let url = reviewFile(key), folder = url.deletingLastPathComponent()
        guard let data = try? JSONEncoder().encode(files), data.count <= 32 << 20,
              (try? write(data, in: folder, name: url.lastPathComponent)) != nil else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let paths = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                 options: .skipsHiddenFiles)) ?? []
        let entries = paths.compactMap { path -> (URL, Date, Int)? in
            guard let values = try? path.resourceValues(forKeys: keys) else { return nil }
            return (path, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var used = 0
        for (path, _, size) in entries {
            used += size
            if used > 128 << 20 { try? FileManager.default.removeItem(at: path) }
        }
    }
}
