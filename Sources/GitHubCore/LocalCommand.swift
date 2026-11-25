import Foundation
import os

public enum LocalCommand {
    public static func run(_ executable: URL, arguments: [String], environment: [String: String],
                           input: Data? = nil, redacting secret: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try execute(executable, arguments: arguments, environment: environment, input: input, secret: secret)
                })
            }
        }
    }

    private static func execute(_ executable: URL, arguments: [String], environment: [String: String],
                                input: Data?, secret: String?) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.executableURL = executable
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
            if let secret { message = message.replacingOccurrences(of: secret, with: "[redacted]") }
            throw CLIError(message.isEmpty ? "\(executable.lastPathComponent) exited with status \(process.terminationStatus)." : message)
        }
        if let error = inputError.withLock({ $0 }) { throw error }
        return data
    }
}
