// Gated to platforms where Foundation's `Process` exists (macOS/Linux/Windows),
// like the rest of the process layer. iOS-family builds never spawn anything.
#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation
import Logging

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The environment the user's **login shell** exports — resolved once per process
/// and layered under every subprocess the SDK spawns (stdio MCP servers, ACP
/// agents, skill scripts and probes).
///
/// A GUI app launched from Finder or the Dock inherits launchd's minimal
/// environment: `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and nothing from the
/// user's shell profile is visible — not Homebrew, not nvm/fnm/volta, cargo,
/// pipx/uv, Go, `~/.local/bin`, nor variables like `NVM_DIR` or `JAVA_HOME`.
/// Hard-coding a few directories cannot keep up with version managers, so this
/// does what editors settled on (VS Code's `resolveShellEnv`, Zed's
/// `shell_env`): run the login shell interactively (`$SHELL -i -l -c`), have it
/// print its environment between two markers, and capture that. Interactive
/// matters because `nvm`-style initialisation typically lives in `.zshrc`,
/// which only interactive shells read.
///
/// Resolution is lazy, cached for the lifetime of the process, serialised so
/// concurrent first callers spawn one shell, and bounded by ``timeout``. On any
/// failure it resolves to an empty set, which leaves the process environment
/// (plus `DefaultProcessExecutionSupport`'s PATH defaults) in effect — never
/// worse than before.
public enum KeepTalkingLoginShellEnvironment {
    /// Exported into the resolving shell so profile scripts can skip slow or
    /// interactive work — the same convention as `VSCODE_RESOLVING_ENVIRONMENT`.
    public static let resolvingMarkerVariable = "KEEPTALKING_RESOLVING_ENVIRONMENT"

    /// How long the login shell gets to print its environment before it is
    /// killed and resolution gives up for this process.
    public static let timeout: TimeInterval = 10

    /// Variables that describe the resolving shell run itself, not the user's
    /// setup, and must not leak into spawned processes.
    static let excludedVariables: Set<String> = [
        "SHLVL", "PWD", "OLDPWD", "_", resolvingMarkerVariable,
    ]

    private static let cache = Cache()
    private static let logger = Logger(label: "keepTalking.process.loginShellEnvironment")

    /// The login shell's exported variables (minus ``excludedVariables``), or an
    /// empty dictionary when they could not be resolved. Blocks the first caller
    /// for the duration of one shell start-up; later calls return the cache.
    public static func resolve() -> [String: String] {
        cache.value(orResolve: resolveNow)
    }

    /// Starts resolution on a background queue so the first spawn doesn't pay
    /// for it. Call once at app launch (the app delegate does).
    public static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            _ = resolve()
        }
    }

    /// Drops the cached result so the next ``resolve()`` runs the shell again —
    /// after the user edits their profile, for instance.
    public static func invalidate() {
        cache.reset()
    }

    // MARK: - Resolution

    static func resolveNow() -> [String: String] {
        let processEnvironment = ProcessInfo.processInfo.environment
        // A profile that itself launches something SDK-backed would otherwise
        // recurse: the nested process sees the marker and stops here.
        guard processEnvironment[resolvingMarkerVariable] == nil else {
            return [:]
        }
        guard let shell = loginShellPath(environment: processEnvironment) else {
            logger.warning("No usable login shell found; subprocesses keep the process environment.")
            return [:]
        }

        let marker = "__KT_LOGIN_ENV_\(UUID().uuidString)__"
        let started = Date()
        do {
            let output = try capture(shell: shell, marker: marker, environment: processEnvironment)
            let variables = parse(output, marker: marker)
            if variables.isEmpty {
                logger.warning(
                    "Login shell \(shell) printed no environment; subprocesses keep the process environment."
                )
            } else {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                logger.info(
                    "Resolved \(variables.count) variables from login shell \(shell) in \(elapsed)ms."
                )
            }
            return variables
        } catch {
            logger.warning(
                "Login shell \(shell) environment resolution failed: \(error.localizedDescription)"
            )
            return [:]
        }
    }

    /// The user's login shell: `$SHELL`, then the account's shell from the
    /// passwd database, then platform defaults — the first that exists and is
    /// not a `nologin`/`false` placeholder.
    static func loginShellPath(environment: [String: String]) -> String? {
        var candidates: [String] = []
        if let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !shell.isEmpty
        {
            candidates.append(shell)
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            candidates.append(String(cString: shell))
        }
        #if os(macOS)
        candidates.append("/bin/zsh")
        #endif
        candidates.append(contentsOf: ["/bin/bash", "/usr/bin/bash", "/bin/sh"])

        let fileManager = FileManager.default
        return candidates.first { candidate in
            let name = URL(fileURLWithPath: candidate).lastPathComponent
            guard name != "nologin", name != "false" else { return false }
            return fileManager.isExecutableFile(atPath: candidate)
        }
    }

    enum ResolutionError: Error, LocalizedError {
        case timedOut(TimeInterval)
        case exited(Int32)

        var errorDescription: String? {
            switch self {
                case .timedOut(let seconds):
                    return "the shell did not finish within \(Int(seconds))s"
                case .exited(let status):
                    return "the shell exited with status \(status)"
            }
        }
    }

    /// Runs `shell -i -l -c '<print env between markers>'` and returns its
    /// stdout. Output goes to a temp file rather than a pipe: a profile that
    /// starts a background daemon (ssh-agent, gpg-agent) would keep a pipe's
    /// write end open long after the shell exits and hang a read-to-end.
    static func capture(
        shell: String,
        marker: String,
        environment: [String: String]
    ) throws -> Data {
        // `env -0` NUL-separates entries so multi-line values survive; the
        // markers fence the dump off from anything the profile prints.
        let script =
            "printf '%s' '\(marker)'; /usr/bin/env -0 || env -0; printf '%s' '\(marker)'"

        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kt-login-env-\(UUID().uuidString.lowercased())")
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        defer { try? fileManager.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        var shellEnvironment = environment
        shellEnvironment[resolvingMarkerVariable] = "1"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Separate flags rather than `-ilc`: every POSIX shell and fish accept them.
        process.arguments = ["-i", "-l", "-c", script]
        process.environment = shellEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // The child holds its own descriptor; release ours.
        try? outputHandle.close()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Our own helper shell: nothing to lose by killing it outright.
            if process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 { kill(pid, SIGKILL) }
            }
            _ = finished.wait(timeout: .now() + 1)
            throw ResolutionError.timedOut(timeout)
        }

        let data = try Data(contentsOf: outputURL)
        // A non-zero status with a complete dump is still usable (a noisy
        // profile may end with a failing command); only an empty dump is fatal.
        if data.isEmpty, process.terminationStatus != 0 {
            throw ResolutionError.exited(process.terminationStatus)
        }
        return data
    }

    /// Extracts `KEY=VALUE` entries from the NUL-separated dump between the two
    /// markers. Anything outside the markers (profile chatter) is ignored, as
    /// are entries without a key and the ``excludedVariables``.
    static func parse(_ data: Data, marker: String) -> [String: String] {
        guard let markerData = marker.data(using: .utf8),
            let first = data.range(of: markerData),
            let last = data.range(of: markerData, options: .backwards),
            first.upperBound <= last.lowerBound
        else {
            return [:]
        }

        var variables: [String: String] = [:]
        for entry in data[first.upperBound..<last.lowerBound].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let separator = text.firstIndex(of: "="), separator != text.startIndex else {
                continue
            }
            let key = String(text[..<separator])
            guard !excludedVariables.contains(key) else { continue }
            variables[key] = String(text[text.index(after: separator)...])
        }
        return variables
    }

    /// Serialises resolution: concurrent first callers block on the queue and
    /// then all read the one result.
    private final class Cache: @unchecked Sendable {
        private let queue = DispatchQueue(label: "keepTalking.process.loginShellEnvironment")
        private var stored: [String: String]?

        func value(orResolve resolve: () -> [String: String]) -> [String: String] {
            queue.sync {
                if let stored { return stored }
                let resolved = resolve()
                stored = resolved
                return resolved
            }
        }

        func reset() {
            queue.sync { stored = nil }
        }
    }
}
#endif
