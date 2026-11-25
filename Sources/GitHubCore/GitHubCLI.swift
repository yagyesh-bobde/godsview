import Foundation

public struct CLIError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

public protocol CommandRunning: Sendable {
    func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data
}

public struct GitHubCLI: CommandRunning {
    public init() {}

    public func run(_ arguments: [String], token: String?, input: Data?) async throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        // Finder-launched apps usually inherit only the system PATH.
        let path = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        guard let binary = path.split(separator: ":").map({ String($0) + "/gh" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CLIError("Install GitHub CLI with brew install gh, then refresh.")
        }
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        environment["GH_TOKEN"] = token
        environment["GH_HOST"] = "github.com"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["PATH"] = path

        return try await LocalCommand.run(URL(fileURLWithPath: binary), arguments: arguments,
                                          environment: environment, input: input, redacting: token)
    }
}
