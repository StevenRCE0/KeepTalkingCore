import Foundation

/// Abstract sandbox backend that compiles action descriptors into a platform
/// process-confinement policy.
///
/// Cross-platform abstraction; backends are platform-specific (`SeatbeltSandbox`
/// on macOS, a future `JailSandbox` for FreeBSD `jail(2)` or bubblewrap/landlock
/// on Linux). Consumers depend only on this protocol.
public protocol ProcessSandboxing: Sendable {

    /// Compiles the sandbox-relevant portions of a descriptor (verbs + object resource)
    /// into a platform-specific policy.
    func compilePolicy(
        descriptor: KeepTalkingActionDescriptor
    ) throws -> KTSandboxPolicy

    /// Applies a compiled policy to a process before it is launched.
    ///
    /// Called between process configuration and `process.run()`. The backend may
    /// rewrite the process executable, arguments, or environment as needed.
    func apply(policy: KTSandboxPolicy, to process: Process) throws
}
