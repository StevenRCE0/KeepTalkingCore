#if os(macOS)
import Foundation

enum SeatbeltSandboxError: Error {
    case noConstraints
    case profileEncodingFailed
}

/// macOS sandbox backend using `sandbox-exec` (seatbelt) for process confinement.
///
/// Compiles `KeepTalkingActionDescriptor` verbs and object resources into a
/// Scheme profile string, then applies it by rewriting the process launch
/// to go through `/usr/bin/sandbox-exec -p <profile>`.
public struct SeatbeltSandbox: ProcessSandboxing {

    public init() {}

    public func compilePolicy(
        descriptor: KeepTalkingActionDescriptor
    ) throws -> KTSandboxPolicy {
        guard descriptor.hasSandboxConstraints,
            let verbs = descriptor.action?.verbs
        else {
            throw SeatbeltSandboxError.noConstraints
        }

        let profile = compileProfile(
            verbs: verbs,
            resource: descriptor.object?.resource,
            directories: descriptor.directories
        )
        guard let data = profile.data(using: .utf8) else {
            throw SeatbeltSandboxError.profileEncodingFailed
        }

        return KTSandboxPolicy(
            descriptor: descriptor,
            platformPayload: data
        )
    }

    public func apply(policy: KTSandboxPolicy, to process: Process) throws {
        guard let profile = String(data: policy.platformPayload, encoding: .utf8),
            !profile.isEmpty
        else { return }

        let originalExecutable = process.executableURL?.path ?? "/usr/bin/env"
        let originalArguments = process.arguments ?? []

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, originalExecutable] + originalArguments

        // Inject descriptor environment variables into the process.
        if let env = policy.descriptor.environment, !env.isEmpty {
            var merged = process.environment ?? ProcessInfo.processInfo.environment
            for (key, value) in env {
                merged[key] = value
            }
            process.environment = merged
        }

        // Inject directory paths as environment variables (e.g. PROJECT_ROOT=/path).
        if let dirs = policy.descriptor.directories, !dirs.isEmpty {
            var merged = process.environment ?? ProcessInfo.processInfo.environment
            for (name, url) in dirs {
                merged[name.uppercased()] = url.path
            }
            process.environment = merged
        }
    }

    // MARK: - Profile compilation

    private func compileProfile(
        verbs: Set<KeepTalkingActionVerb>,
        resource: KeepTalkingActionResource?,
        directories: [String: URL]?
    ) -> String {
        var rules: [String] = []

        // Baseline: always allow basic process operations
        rules.append(contentsOf: baselineRules())

        // Verb-specific rules scoped to the resource
        if let resource {
            switch resource {
                case .filePaths(let urls):
                    let paths = urls.map { $0.standardizedFileURL.path }
                    for path in paths {
                        if verbs.contains(.read) || verbs.contains(.grep) || verbs.contains(.ls) {
                            rules.append("(allow file-read* (subpath \"\(escapeSeatbelt(path))\"))")
                        }
                        if verbs.contains(.write) {
                            rules.append("(allow file-write* (subpath \"\(escapeSeatbelt(path))\"))")
                        }
                        if verbs.contains(.execute) {
                            rules.append("(allow process-exec (subpath \"\(escapeSeatbelt(path))\"))")
                        }
                    }

                case .urls(let urls):
                    if verbs.contains(.network) || verbs.contains(.callTool) {
                        for url in urls {
                            if let host = url.host {
                                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                                rules.append(
                                    "(allow network-outbound (remote tcp \"\(escapeSeatbelt(host)):\(port)\"))"
                                )
                            }
                        }
                    }

                case .command(let commandSets):
                    if verbs.contains(.execute) {
                        for command in commandSets {
                            guard let executable = command.first else { continue }
                            let resolved = URL(fileURLWithPath: executable).standardizedFileURL.path
                            rules.append("(allow process-exec (literal \"\(escapeSeatbelt(resolved))\"))")
                            // Allow reading the executable
                            rules.append("(allow file-read* (literal \"\(escapeSeatbelt(resolved))\"))")
                        }
                    }
            }
        }

        // Named base directories from the descriptor
        if let directories, !directories.isEmpty {
            for (_, url) in directories {
                let path = url.standardizedFileURL.path
                rules.append("(allow file-read* (subpath \"\(escapeSeatbelt(path))\"))")
                if verbs.contains(.write) {
                    rules.append("(allow file-write* (subpath \"\(escapeSeatbelt(path))\"))")
                }
            }
        }

        // Interpreter paths needed for script execution
        if verbs.contains(.execute) {
            rules.append(contentsOf: interpreterRules())
        }

        return "(version 1)\n(deny default)\n" + rules.joined(separator: "\n")
    }

    private func baselineRules() -> [String] {
        let tmpdir = DefaultProcessExecutionSupport.resolveWritableTempDirectory(
            environment: ProcessInfo.processInfo.environment
        )
        return [
            // Process metadata and basic syscalls
            "(allow process-fork)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",

            // Temp directory access
            "(allow file-read* (subpath \"\(escapeSeatbelt(tmpdir))\"))",
            "(allow file-write* (subpath \"\(escapeSeatbelt(tmpdir))\"))",

            // System libraries and frameworks
            "(allow file-read* (subpath \"/usr/lib\"))",
            "(allow file-read* (subpath \"/usr/share\"))",
            "(allow file-read* (subpath \"/System\"))",
            "(allow file-read* (subpath \"/Library/Frameworks\"))",
            "(allow file-read* (subpath \"/private/var/db\"))",

            // Dynamic linker
            "(allow file-read* (literal \"/dev/null\"))",
            "(allow file-read* (literal \"/dev/urandom\"))",
        ]
    }

    private func interpreterRules() -> [String] {
        let interpreters = [
            "/usr/bin/env",
            "/bin/zsh",
            "/bin/sh",
            "/bin/bash",
            "/usr/bin/python3",
        ]
        var rules: [String] = []
        for path in interpreters {
            rules.append("(allow process-exec (literal \"\(escapeSeatbelt(path))\"))")
            rules.append("(allow file-read* (literal \"\(escapeSeatbelt(path))\"))")
        }
        // Homebrew interpreters
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            rules.append("(allow process-exec (subpath \"\(escapeSeatbelt(prefix))\"))")
            rules.append("(allow file-read* (subpath \"\(escapeSeatbelt(prefix))\"))")
        }
        return rules
    }

    private func escapeSeatbelt(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
