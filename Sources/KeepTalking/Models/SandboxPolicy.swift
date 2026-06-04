import Foundation

/// A compiled sandbox policy ready for platform-specific process confinement.
///
/// Consumers treat this as opaque — they pass it through to a `ProcessSandboxing`
/// backend which applies the `platformPayload` at process launch time.
/// The `descriptor` records the SVO constraints that produced this policy.
///
/// The policy is plain data and so is cross-platform; only the enforcing backend
/// (e.g. `SeatbeltSandbox` on macOS) is platform-specific. On platforms with no
/// backend the policy simply isn't applied (the subprocess runs unsandboxed).
public struct KTSandboxPolicy: Sendable {

    /// The merged descriptor whose verbs and object resource drove this policy.
    public let descriptor: KeepTalkingActionDescriptor

    /// Opaque, backend-specific payload (e.g. a compiled seatbelt Scheme profile).
    let platformPayload: Data

    public init(
        descriptor: KeepTalkingActionDescriptor,
        platformPayload: Data = Data()
    ) {
        self.descriptor = descriptor
        self.platformPayload = platformPayload
    }
}
