#if os(macOS)
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Proves the Workstream-1 unification: a grant scope narrows the COMPILED
/// sandbox policy, not just the in-process call gate. Assertions are scoped to
/// the action's own root path because `SeatbeltSandbox` baseline rules always
/// emit `file-read*`/`file-write*` for the temp directory.
struct ScopeResolverScopeTests {
    private let root = "/tmp/kt-scope-test-root"
    private var readRuleForRoot: String { "file-read* (subpath \"\(root)\"" }
    private var writeRuleForRoot: String { "file-write* (subpath \"\(root)\"" }

    private func filesystemAction() -> KeepTalkingAction {
        let action = KeepTalkingAction(
            payload: .filesystem(KeepTalkingFilesystemBundle(rootPath: root)),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        // `descriptor` is a Fluent `@Field` (not `@OptionalField`): reading it
        // before it's set traps. A real action is always DB-fetched or has its
        // descriptor assigned; initialize it to nil here so `resolvedDescriptor`
        // falls through to the implicit filesystem descriptor.
        action.descriptor = nil
        return action
    }

    private func profile(callerScope: KeepTalkingActionScope) throws -> String {
        let policy = try ScopeResolver.resolvedPolicy(
            for: filesystemAction(),
            callerScope: callerScope,
            sandbox: SeatbeltSandbox()
        )
        return String(decoding: policy.platformPayload, as: UTF8.self)
    }

    @Test("read-only grant → root is readable but NOT writable in the seatbelt profile")
    func readOnlyGrantNarrowsSandbox() throws {
        let profile = try profile(callerScope: .verbs([.read, .ls, .grep]))
        #expect(profile.contains(readRuleForRoot))
        #expect(!profile.contains(writeRuleForRoot))
    }

    @Test("write grant → root is writable in the seatbelt profile")
    func writeGrantAllowsWrite() throws {
        let profile = try profile(callerScope: .verbs([.read, .ls, .grep, .write]))
        #expect(profile.contains(writeRuleForRoot))
    }

    @Test("`.all` grant → full filesystem capability (root readable AND writable)")
    func allScopeKeepsFullCapability() throws {
        let profile = try profile(callerScope: .all)
        #expect(profile.contains(readRuleForRoot))
        #expect(profile.contains(writeRuleForRoot))
    }
}
#endif
