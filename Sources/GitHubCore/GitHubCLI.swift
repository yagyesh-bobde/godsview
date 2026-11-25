import Foundation
import os

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
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try execute(arguments, token: token, input: input) })
            }
        }
    }

    private func execute(_ arguments: [String], token: String?, input: Data?) throws -> Data {
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

        // Keep blocking pipe I/O off Swift's cooperative executor. Drain stderr
        // independently so a full pipe cannot stall the child or its stdout reader.
        let readers = DispatchGroup()
        let diagnostics = OSAllocatedUnfairLock(initialState: Data())
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            let bytes = errors.fileHandleForReading.readDataToEndOfFile()
            diagnostics.withLock { $0 = bytes }
        }
        let inputError = OSAllocatedUnfairLock(initialState: Optional<Error>.none)
        if let input {
            DispatchQueue.global(qos: .userInitiated).async(group: readers) {
                let handle = stdin.fileHandleForWriting
                _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                defer { try? handle.close() }
                do { try handle.write(contentsOf: input) }
                catch { inputError.withLock { $0 = error } }
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        readers.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            var message = diagnostics.withLock { String(decoding: $0, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
            if let token { message = message.replacingOccurrences(of: token, with: "[redacted]") }
            throw CLIError(message.isEmpty ? "GitHub CLI exited with status \(process.terminationStatus)." : message)
        }
        if let error = inputError.withLock({ $0 }) { throw error }
        return data
    }
}
