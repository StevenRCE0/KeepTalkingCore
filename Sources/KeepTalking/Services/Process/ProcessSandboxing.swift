#if os(macOS)
import Foundation

/// Abstract sandbox backend that compiles action descriptors into macOS seatbelt policies.
///
/// Future backends (e.g. `JailSandbox` for FreeBSD `jail(2)`) conform to this same
/// protocol without touching consumers.
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
#endif
