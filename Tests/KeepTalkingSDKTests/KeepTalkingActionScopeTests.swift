import Foundation
import Testing

@testable import KeepTalkingSDK

struct KeepTalkingActionScopeTests {

    // MARK: - allows

    @Test("`.all` allows every structural verb; `.verbs` allows only its members")
    func allowsStructural() {
        #expect(KeepTalkingActionScope.all.allows(.read))
        #expect(KeepTalkingActionScope.all.allows(.execute))

        let readOnly = KeepTalkingActionScope.verbs([.read, .ls, .grep])
        #expect(readOnly.allows(.read))
        #expect(readOnly.allows(.ls))
        #expect(!readOnly.allows(.write))
        #expect(!readOnly.allows(.execute))
    }

    // MARK: - permitsNamed

    @Test("named-resource permission honours the class wildcard and explicit names")
    func permitsNamed() {
        // `.all` permits anything.
        #expect(KeepTalkingActionScope.all.permitsNamed("anything", classWildcard: .callTool))

        // Class wildcard present → all names of that class.
        let allTools = KeepTalkingActionScope.verbs([.callTool])
        #expect(allTools.permitsNamed("search", classWildcard: .callTool))
        #expect(allTools.permitsNamed("delete", classWildcard: .callTool))

        // Only an explicit name → just that name.
        let onlySearch = KeepTalkingActionScope.verbs([.named("search")])
        #expect(onlySearch.permitsNamed("search", classWildcard: .callTool))
        #expect(!onlySearch.permitsNamed("delete", classWildcard: .callTool))

        // Empty scope denies everything.
        let denied = KeepTalkingActionScope.verbs([])
        #expect(!denied.permitsNamed("search", classWildcard: .callTool))
    }

    // MARK: - allowedNames

    @Test("allowedNames: nil = unfiltered, explicit names otherwise")
    func allowedNames() {
        #expect(KeepTalkingActionScope.all.allowedNames(classWildcard: .callTool) == nil)

        // Class wildcard → unfiltered (nil).
        #expect(
            KeepTalkingActionScope.verbs([.callTool]).allowedNames(classWildcard: .callTool) == nil
        )

        // Explicit names → those names (order-independent).
        let names = KeepTalkingActionScope.verbs([.named("a"), .named("b")])
            .allowedNames(classWildcard: .callTool)
        #expect(Set(names ?? []) == ["a", "b"])

        // Primitive-style (no class wildcard): only `.all` is unfiltered.
        #expect(KeepTalkingActionScope.all.allowedNames(classWildcard: nil) == nil)
        #expect(
            Set(KeepTalkingActionScope.verbs([.named("read")]).allowedNames(classWildcard: nil) ?? [])
                == ["read"]
        )
        // A `.verbs` set with no named tokens → empty allowlist (deny all named).
        #expect(KeepTalkingActionScope.verbs([.write]).allowedNames(classWildcard: nil) == [])
    }

    // MARK: - isDenied

    @Test("isDenied is true only for an empty `.verbs` set")
    func isDenied() {
        #expect(KeepTalkingActionScope.verbs([]).isDenied)
        #expect(!KeepTalkingActionScope.all.isDenied)
        #expect(!KeepTalkingActionScope.verbs([.read]).isDenied)
        #expect(!KeepTalkingActionScope.verbs([.named("x")]).isDenied)
    }

    // MARK: - union

    @Test("union: `.all` dominates; verb sets widen; wildcards survive")
    func union() {
        // `.all` dominates.
        if case .all = KeepTalkingActionScope.union([.verbs([.read]), .all]) {
        } else {
            Issue.record("Expected `.all` to dominate the union")
        }

        // The all-tools wildcard survives union with a narrow named grant, so the
        // result still permits every tool (no silent over-restriction).
        let widened = KeepTalkingActionScope.union([
            .verbs([.callTool]), .verbs([.named("search")]),
        ])
        #expect(widened.permitsNamed("delete", classWildcard: .callTool))

        // Verb sets merge.
        if case .verbs(let set) = KeepTalkingActionScope.union([
            .verbs([.read]), .verbs([.write]),
        ]) {
            #expect(set == [.read, .write])
        } else {
            Issue.record("Expected merged `.verbs`")
        }

        // Empty input → deny.
        #expect(KeepTalkingActionScope.union([]).isDenied)
    }

    // MARK: - Codable

    @Test("scope Codable round-trips `.all`, `.verbs`, and `.named` tokens")
    func scopeCodableRoundTrip() throws {
        let cases: [KeepTalkingActionScope] = [
            .all,
            .verbs([.read, .write, .execute]),
            .verbs([.callTool, .named("search")]),
            .verbs([]),
        ]
        for scope in cases {
            let data = try JSONEncoder().encode(scope)
            let decoded = try JSONDecoder().decode(KeepTalkingActionScope.self, from: data)
            #expect(decoded == scope)
        }
    }

    @Test("`.named(\"read\")` does NOT collide with the structural `.read` token")
    func namedDoesNotCollideWithStructural() throws {
        let named = KeepTalkingActionVerb.named("read")
        let data = try JSONEncoder().encode(named)
        let decoded = try JSONDecoder().decode(KeepTalkingActionVerb.self, from: data)
        #expect(decoded == .named("read"))
        #expect(decoded != .read)

        // Structural still round-trips as structural.
        let readData = try JSONEncoder().encode(KeepTalkingActionVerb.read)
        #expect(try JSONDecoder().decode(KeepTalkingActionVerb.self, from: readData) == .read)
    }

    @Test("verb rawValue stays stable for string consumers")
    func verbRawValueStable() {
        #expect(KeepTalkingActionVerb.callTool.rawValue == "call-tool")
        #expect(KeepTalkingActionVerb.read.rawValue == "read")
        #expect(KeepTalkingActionVerb.named("foo").rawValue == "foo")
        // init?(rawValue:) recognises only structural tokens.
        #expect(KeepTalkingActionVerb(rawValue: "read") == .read)
        #expect(KeepTalkingActionVerb(rawValue: "not-a-verb") == nil)
    }
}
