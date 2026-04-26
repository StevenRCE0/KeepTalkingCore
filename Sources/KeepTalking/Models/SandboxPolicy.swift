import Foundation

#if os(macOS)
/// A compiled sandbox policy ready for platform-specific process confinement.
///
/// Consumers treat this as opaque — they pass it through to a `ProcessSandboxing`
/// backend which applies the `platformPayload` at process launch time.
/// The `descriptor` records the SVO constraints that produced this policy.
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
#else
/// Stub on platforms without process sandboxing. Lets the cross-platform
/// `SkillManager` API keep a `sandboxPolicy:` parameter without forcing every
/// call site to be `#if os(macOS)`. iOS code paths ignore the value — script
/// execution there is delegated to a different protocol that doesn't take a
/// sandbox policy.
public struct KTSandboxPolicy: Sendable {
    public init() {}
}
#endif
