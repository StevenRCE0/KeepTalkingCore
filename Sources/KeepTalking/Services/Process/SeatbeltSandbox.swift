#if os(macOS)
import Darwin
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
            directories: descriptor.directories,
            directoryDirections: descriptor.directoryDirections
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
        // Use the STANDARDIZED (not realpath) path so the value matches the form the
        // resource manifest emits and the agent-path scrubber rewrites — the grant
        // itself is realpath-canonical, and the kernel resolves the /var → /private
        // symlink when the process opens the path, so access still matches the grant.
        // (Injecting the realpath form here would leak a "/private/var…" the scrubber
        // can't match against its "/var…" table.)
        if let dirs = policy.descriptor.directories, !dirs.isEmpty {
            var merged = process.environment ?? ProcessInfo.processInfo.environment
            for (name, url) in dirs {
                merged[name.uppercased()] = url.standardizedFileURL.path
            }
            process.environment = merged
        }
    }

    /// The kernel-resolved real path (via `realpath`), matching how seatbelt
    /// canonicalises an accessed path before testing it against the profile.
    /// Falls back to the standardized path when the target doesn't exist yet
    /// (e.g. a not-yet-created output file — covered by its parent dir grant).
    func canonicalPath(_ url: URL) -> String {
        let raw = url.standardizedFileURL.path
        guard let resolved = realpath(raw, nil) else { return raw }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Profile compilation

    private func compileProfile(
        verbs: Set<KeepTalkingActionVerb>,
        resource: KeepTalkingActionResource?,
        directories: [String: URL]?,
        directoryDirections: [String: KeepTalkingResourceDirection]? = nil
    ) -> String {
        var rules: [String] = []

        // Baseline: always allow basic process operations
        rules.append(contentsOf: baselineRules())

        // Verb-specific rules scoped to the resource
        if let resource {
            switch resource {
                case .filePaths(let urls):
                    // Canonicalise via realpath: seatbelt matches against the
                    // kernel-resolved real path (/var → /private/var, /tmp →
                    // /private/tmp), and `resolvingSymlinksInPath()` does NOT
                    // resolve those (Foundation's /private special-casing), so a
                    // grant on a staged file under /var/folders would never match.
                    let paths = urls.map { canonicalPath($0) }
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

        // Named base directories from the descriptor. Each is readable; write is
        // granted per-directory by its declared direction (`.output`/`.inputOutput`
        // → writable), falling back to the global `.write` verb for any directory
        // without a direction entry (legacy named dirs like "project_root").
        if let directories, !directories.isEmpty {
            for (label, url) in directories {
                // realpath-canonicalised for the same reason as file-path grants
                // above — a workspace/staging dir under /var/folders must be granted
                // by its /private/var/folders real path or seatbelt denies access.
                let path = canonicalPath(url)
                rules.append("(allow file-read* (subpath \"\(escapeSeatbelt(path))\"))")
                let wantsWrite: Bool
                if let direction = directoryDirections?[label] {
                    wantsWrite = direction == .output || direction == .inputOutput
                } else {
                    wantsWrite = verbs.contains(.write)
                }
                if wantsWrite {
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
            // Low-level system foundation. dyld + any real binary need a set of
            // mach services, shared-cache reads, and syscalls that a hand-rolled
            // allow-list misses on modern macOS — without this even `/bin/cat`
            // aborts with SIGABRT before running. `bsd.sb` provides exactly that
            // floor while leaving `(deny default)` in force for files and network,
            // so confinement is unchanged (ungranted reads/writes and network stay
            // denied; the explicit grants below re-open only what the action needs).
            "(import \"bsd.sb\")",

            // Process metadata and basic syscalls. `bsd.sb` does NOT grant
            // process-fork, so without this a shell pipeline (which forks) fails
            // with "fork failed: operation not permitted".
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

    /// Exec grants for the execution environment (active only with the `execute`
    /// verb). The agent's `kt_shell` runs `/bin/zsh -c …` and from there reaches
    /// for ordinary system tools (cat/ls/grep/head/python3/git/…), so a shell that
    /// could exec only five interpreters would be useless. We therefore allow
    /// `process-exec` of the system binary directories. This is NOT a confinement
    /// hole: the file-read*/file-write* rules still gate what those tools can touch
    /// (only the skill dir, granted directories, the workspace, and /tmp), network
    /// stays denied unless the `network` verb opened it, and `appleevent-send` is
    /// never granted, so a tool like `osascript` cannot drive other apps.
    private func interpreterRules() -> [String] {
        var rules: [String] = []
        // Standard system + package-manager binary directories — read + exec.
        let executableRoots = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            // Full trees: Homebrew/local binaries are symlinks into Cellar/opt, so
            // following them to exec the real file needs the whole subtree.
            "/opt/homebrew",
            "/usr/local",
        ]
        for prefix in executableRoots {
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
