#if os(macOS)
import Foundation

public enum MacOSShortcuts {
    /// Lists all macOS Shortcuts by name, sorted alphabetically.
    /// Runs `/usr/bin/shortcuts list` on a background thread to avoid blocking the caller.
    public static func list() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["list"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let names = output.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .sorted()
                    continuation.resume(returning: names)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
#endif
