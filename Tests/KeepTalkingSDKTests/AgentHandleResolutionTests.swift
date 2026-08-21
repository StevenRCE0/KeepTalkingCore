import Foundation
import Testing

@testable import KeepTalkingSDK

/// Resource handles as the agent handles them.
///
/// Handles keep their hex form — the string is also the skill's `$KT_…`
/// environment-variable name and part of the signed `resourcesHash` the plugin
/// SDK verifies, so it cannot become words without a breaking wire change.
/// What it can do is stop being a dead end: given the set of handles that
/// actually exist, a single mistyped character is answerable.
struct AgentHandleResolutionTests {

    private func handle(_ id: UUID, _ kind: KTResourceManifest.Kind = .otb) -> String {
        KTResourceManifest.agentHandle(kind: kind, id: id)
    }

    @Test("an exact handle resolves")
    func exactHandleResolves() {
        let id = UUID()
        let other = UUID()
        #expect(
            KTResourceManifest.resolveAgentHandle(handle(id), among: [id, other])
                == .resolved(id))
    }

    @Test("a bare UUID resolves, as lenient ingest already allowed")
    func bareUUIDResolves() {
        let id = UUID()
        #expect(
            KTResourceManifest.resolveAgentHandle(id.uuidString, among: [id])
                == .resolved(id))
    }

    @Test("one wrong hex digit is repaired to the only handle it can have meant")
    func singleWrongDigitIsRepaired() throws {
        let id = UUID()
        let other = UUID()
        var chars = Array(handle(id))
        // Corrupt the last hex digit the way a model drops one.
        chars[chars.count - 1] = chars[chars.count - 1] == "A" ? "B" : "A"
        let mistyped = String(chars)
        try #require(mistyped != handle(id))

        guard
            case .corrected(let resolved, _, _) =
                KTResourceManifest.resolveAgentHandle(mistyped, among: [id, other])
        else {
            Issue.record("expected repair, got \(KTResourceManifest.resolveAgentHandle(mistyped, among: [id, other]))")
            return
        }
        #expect(resolved == id)
    }

    @Test("a dropped character is repaired too")
    func droppedCharacterIsRepaired() {
        let id = UUID()
        let mistyped = String(handle(id).dropLast())

        guard
            case .corrected(let resolved, _, _) =
                KTResourceManifest.resolveAgentHandle(mistyped, among: [id])
        else {
            Issue.record("expected repair of a dropped character")
            return
        }
        #expect(resolved == id)
    }

    @Test("a handle for something not offered resolves to nothing")
    func handleOutsideCandidateSetIsUnknown() {
        // Well-formed but not on offer — repairing to *something* would be worse
        // than failing, so it must not.
        #expect(
            KTResourceManifest.resolveAgentHandle(handle(UUID()), among: [UUID()])
                == .unknown)
    }

    @Test("two plausible readings are refused rather than guessed")
    func ambiguityIsRefused() throws {
        // Two candidates differing only in their final character, and a typed
        // handle whose final character matches neither — one edit from both.
        let a = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA"))
        let b = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAB"))
        let between = String(handle(a).dropLast()) + "C"

        guard
            case .ambiguous(let ids) =
                KTResourceManifest.resolveAgentHandle(between, among: [a, b])
        else {
            Issue.record("expected ambiguity, not a guess")
            return
        }
        #expect(Set(ids) == Set([a, b]))
    }

    @Test("a filename is not mistaken for a handle")
    func filenameIsNotAHandle() {
        // The realistic wrong input: the agent passes what it can see rather
        // than the opaque handle. It must fail, not resolve to something.
        #expect(
            KTResourceManifest.resolveAgentHandle("report.pdf", among: [UUID()])
                == .unknown)
        #expect(
            KTResourceManifest.resolveAgentHandle(
                "/Users/steven/report.pdf", among: [UUID()]) == .unknown)
    }

    @Test("the canonical handle shape is unchanged, so the wire contract holds")
    func handleShapeIsUnchanged() throws {
        // KTPPResourceEntry.handle is this string, and it is canonicalized into
        // the signed resourcesHash the Python SDK verifies. It must stay
        // KT_<KIND>_<32 uppercase hex>.
        let id = try #require(UUID(uuidString: "019EBBD5-8D87-7000-946E-76135023BD00"))
        #expect(handle(id) == "KT_OTB_019EBBD58D877000946E76135023BD00")
        #expect(KTResourceManifest.parseAgentHandle(handle(id))?.id == id)
        #expect(KTResourceManifest.parseAgentHandle(handle(id))?.kind == .otb)
    }

    // MARK: - The friendly name a resource also carries

    @Test("a resource carries the friendly name of the id inside its handle")
    func resourceCarriesFriendlyName() {
        let id = UUID()
        let resource = KTResourceManifest.AgentResource(
            kind: .otb, id: id, direction: "read", name: "report.pdf", origin: "produced")

        #expect(resource.friendlyName == id.friendlyNameToken)
        #expect(resource.jsonObject()["friendly"] as? String == id.friendlyNameToken)
        // The handle is still the canonical identity and is unchanged.
        #expect(
            resource.jsonObject()["handle"] as? String
                == KTResourceManifest.agentHandle(kind: .otb, id: id))
    }

    @Test("the friendly name resolves back to the resource it names")
    func friendlyNameResolvesToItsResource() {
        // What the agent does: copies the readable name instead of 32 hex digits.
        let id = UUID()
        let other = UUID()
        #expect(
            UUIDFriendlyName.resolve(id.friendlyName, among: [id, other])
                == .resolved(id))
        #expect(
            UUIDFriendlyName.resolve(id.friendlyNameToken, among: [id, other])
                == .resolved(id))
    }

    @Test("a friendly name for a resource not on offer resolves to nothing")
    func friendlyNameOutsideCandidateSetIsUnknown() {
        // A name is a hash: it only means something against handles that exist.
        // Resolving it to *something* would be worse than failing.
        #expect(
            UUIDFriendlyName.resolve(UUID().friendlyName, among: [UUID()]) == .unknown)
    }

    @Test("a resource with a non-KT handle has no friendly name rather than a wrong one")
    func nonKTHandleHasNoFriendlyName() {
        let resource = KTResourceManifest.AgentResource(
            handle: "not-a-kt-handle", kind: "otb", direction: "read",
            name: "x", origin: "produced")
        #expect(resource.friendlyName == nil)
        #expect(resource.jsonObject()["friendly"] == nil)
    }

    // MARK: - A handle is never the user's alias

    @Test("a node's handle stays its token even when the user set an alias")
    func aliasNeverBecomesTheHandle() {
        let id = UUID()
        let mapping = KeepTalkingMapping(
            target: .node(id), kind: .alias, value: "Steven's MacBook")
        let lookup = KeepTalkingAliasLookup(mappings: [mapping])
        let resolution = lookup.resolve(.node(id))

        // `primary` is a LABEL and prefers the alias — which is why agent
        // surfaces must not use it for identity.
        #expect(resolution.primary(.friendlyToken) == "Steven's MacBook")

        // The handle ignores the alias entirely, so it stays resolvable.
        #expect(resolution.idText(.friendlyToken) == id.friendlyNameToken)
        #expect(
            UUIDFriendlyName.resolve(id.friendlyNameToken, among: [id]) == .resolved(id))
    }

    @Test("an alias cannot be resolved back to the node it labels")
    func aliasDoesNotResolve() {
        // The reason the handle can never be an alias: free text has no decode.
        // If a surface showed the alias as the identifier, that node would be
        // unreferenceable.
        let id = UUID()
        #expect(UUIDFriendlyName.resolve("Steven's MacBook", among: [id]) == .unknown)
    }
}
