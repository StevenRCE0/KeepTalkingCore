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

    @Test("one wrong character is repaired to the only handle it can have meant")
    func singleWrongDigitIsRepaired() throws {
        // Fixed, for the same reason as the deletion test: the word lists are
        // ≥2 edits apart, which detects any single typo but cannot always
        // CORRECT one — a mangled word can sit exactly one edit from two list
        // words that are two apart. Measured, that is ~0.4% of substitutions,
        // enough to make a random id flaky.
        let id = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000000"))
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

    @Test("a dropped character is repaired when the reading is unambiguous")
    func droppedCharacterIsRepaired() throws {
        // A FIXED id, not a random one. Whether a deletion is repairable is a
        // property of the words it lands between, not of the code path — see the
        // test below — so a random id makes this one flaky rather than thorough.
        let id = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000000"))
        try #require(handle(id) == "KT_OTB_SHARP_CIVIC_CLOWNFISH")
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

    @Test("a dropped character with two readings refuses rather than guessing")
    func ambiguousDeletionIsRefused() throws {
        // The word lists are single-typo safe, so a SUBSTITUTION is always
        // attributable. A DELETION is not: dropping the "e" from `ravine` lands
        // one edit from `ravine` and one edit from another noun at the same time,
        // and `nearestWord` refuses a tie. Answering "unknown" is the design
        // working — guessing would hand the caller a different resource.
        let id = try #require(UUID(uuidString: "64F402F2-8DCA-4293-858F-5B5D8BE967BA"))
        try #require(handle(id) == "KT_OTB_SHADOW_INDIGO_RAVINE")
        let mistyped = String(handle(id).dropLast())

        let outcome = KTResourceManifest.resolveAgentHandle(mistyped, among: [id])
        #expect(outcome == .unknown, "a tie must not resolve to a guess")
    }

    @Test("a handle for something not offered resolves to nothing")
    func handleOutsideCandidateSetIsUnknown() {
        // Well-formed but not on offer — repairing to *something* would be worse
        // than failing, so it must not.
        #expect(
            KTResourceManifest.resolveAgentHandle(handle(UUID()), among: [UUID()])
                == .unknown)
    }

    /// The first pair of ids whose 24-bit codes collide, walked from a fixed
    /// counter so the pair is identical on every run.
    ///
    /// A code collision is the ONLY way two handles can genuinely read the same.
    /// A mistyped one cannot be ambiguous: the word lists are single-typo safe by
    /// construction, so at most one list word is ever within one edit of a typo
    /// (see `UUIDFriendlyNameTests.friendlyNameWordListsAreWellFormed`) — which is
    /// why this test does not mistype anything.
    private func collidingIDs(within limit: Int = 60_000) -> (UUID, UUID)? {
        var seenByCode: [UUIDFriendlyName.Code: UUID] = [:]
        for i in 0..<limit {
            guard
                let id = UUID(
                    uuidString: String(format: "%08X-0000-4000-8000-000000000000", i))
            else { continue }
            let code = id.friendlyNameCode
            if let previous = seenByCode[code] { return (previous, id) }
            seenByCode[code] = id
        }
        return nil
    }

    @Test("two plausible readings are refused rather than guessed")
    func ambiguityIsRefused() throws {
        let (a, b) = try #require(collidingIDs(), "no code collision in the scanned range")
        try #require(handle(a) == handle(b), "a collision must render the same handle")

        guard
            case .ambiguous(let ids) =
                KTResourceManifest.resolveAgentHandle(handle(a), among: [a, b])
        else {
            Issue.record(
                "expected ambiguity, got \(KTResourceManifest.resolveAgentHandle(handle(a), among: [a, b]))"
            )
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

    @Test("the canonical handle is a stable, parseable token for a given id")
    func handleShapeIsStable() throws {
        // `KTPPResourceEntry.handle` is this string, and it is canonicalized into
        // the signed `resourcesHash`. The SPELLING is not part of that contract:
        // both ends hash the resources block exactly as transmitted (Swift over
        // what it sends, the Python SDK over what it receives), and nothing on the
        // plugin side parses the handle. What must hold is that a given id always
        // renders the same token, and that the token parses back.
        let id = try #require(UUID(uuidString: "019EBBD5-8D87-7000-946E-76135023BD00"))
        #expect(handle(id) == "KT_OTB_SHARP_SIMPLE_EAGLERAY")
        #expect(handle(id) == handle(id), "a handle must be stable for an id")
        // The kind survives on its own; the id does NOT — a friendly handle
        // carries a 24-bit code, not the UUID, so it only resolves against the
        // handles that exist. That is the whole reason resolveAgentHandle takes
        // a candidate set.
        #expect(KTResourceManifest.parseAgentHandleCode(handle(id))?.kind == .otb)
        #expect(KTResourceManifest.parseAgentHandle(handle(id)) == nil)
        #expect(
            KTResourceManifest.resolveAgentHandle(handle(id), among: [id, UUID()])
                == .resolved(id))
    }

    // MARK: - The friendly name a resource also carries

    @Test("a resource carries the friendly name of the id inside its handle")
    func resourceCarriesFriendlyName() {
        let id = UUID()
        let resource = KTResourceManifest.AgentResource(
            kind: .otb, id: id, direction: "read", name: "report.pdf", origin: "produced")

        #expect(resource.friendlyName == id.friendlyNameToken)
        // No separate `friendly` key: the handle IS the friendly token now, so a
        // second field carrying the same words was dropped as redundant.
        #expect(resource.jsonObject()["friendly"] == nil)
        // The handle is still the canonical identity.
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
