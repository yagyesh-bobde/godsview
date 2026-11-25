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

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice as Any : stdin as Any
        try process.run()

        // Drain both pipes concurrently. A full stderr pipe must never block stdout.
        async let stdout = Self.read(output)
        async let stderr = Self.read(errors)
        if let input {
            let handle = stdin.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            defer { try? handle.close() }
            try handle.write(contentsOf: input)
        }
        let (data, diagnostics) = await (stdout, stderr)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            var message = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let token { message = message.replacingOccurrences(of: token, with: "[redacted]") }
            throw CLIError(message.isEmpty ? "GitHub CLI exited with status \(process.terminationStatus)." : message)
        }
        return data
    }

    private static func read(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }
}
