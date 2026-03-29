#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

enum DefaultProcessExecutionSupport {
    static func mergedEnvironment(
        for command: [String],
        environment overrides: [String: String]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(overrides) { _, new in new }
        environment["PATH"] = resolvePathEnvironment(
            command: command,
            environment: environment
        )
        environment["TMPDIR"] = resolveWritableTempDirectory(
            environment: environment
        )
        if environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        {
            environment["HOME"] = NSHomeDirectory()
        }
        return environment
    }

    static func resolveWritableTempDirectory(
        environment: [String: String]
    ) -> String {
        let fileManager = FileManager.default
        let fallback = "/tmp"
        let candidates = [
            environment["TMPDIR"],
            ProcessInfo.processInfo.environment["TMPDIR"],
            NSTemporaryDirectory(),
            fallback,
        ]
        for candidate in candidates {
            guard let candidate else {
                continue
            }
            let path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                fileManager.isWritableFile(atPath: path)
            else {
                continue
            }
            return path
        }
        return fallback
    }

    static func resolvePathEnvironment(
        command: [String],
        environment: [String: String]
    ) -> String {
        var components = (environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for candidate in defaults where !components.contains(candidate) {
            components.append(candidate)
        }

        if let executable = command.first,
            executable.hasPrefix("/")
        {
            let executableDirectory = URL(fileURLWithPath: executable)
                .deletingLastPathComponent().path
            if !executableDirectory.isEmpty,
                !components.contains(executableDirectory)
            {
                components.insert(executableDirectory, at: 0)
            }
        }

        if components.isEmpty {
            return defaults.joined(separator: ":")
        }
        return components.joined(separator: ":")
    }

    static func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try handle.readToEnd() ?? Data()
        }.value
    }

    static func decode(data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}

final class DefaultProcessExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    func set(status: Int32) {
        lock.lock()
        self.status = status
        lock.unlock()
    }

    func snapshot() -> Int32? {
        lock.lock()
        let result = status
        lock.unlock()
        return result
    }
}
#endif
