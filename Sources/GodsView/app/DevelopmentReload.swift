#if DEBUG
import Foundation

@MainActor
final class DevelopmentReload {
    private let buildKey = "GodsViewDevelopmentBuild"
    private let bundle = Bundle.main.bundleURL
    private let launchedBuild = Bundle.main.object(forInfoDictionaryKey: "GodsViewDevelopmentBuild") as? String
    private var changes: DispatchSourceFileSystemObject?

    func observe(_ check: @escaping @MainActor () -> Void) {
        guard launchedBuild != nil, changes == nil else { return }
        // Packaging atomically swaps the entire .app, so observe its parent directory.
        let directory = open(bundle.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
        guard directory >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directory, eventMask: .write, queue: .main
        )
        source.setEventHandler { check() }
        source.setCancelHandler { close(directory) }
        changes = source
        source.resume()
        check()
    }

    var hasReplacement: Bool {
        guard let launchedBuild,
              let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let installedBuild = info[buildKey] as? String else { return false }
        return launchedBuild != installedBuild
    }

    func stop() {
        changes?.cancel()
        changes = nil
    }
}
#endif
