import Foundation
import Testing

@testable import KeepTalkingSDK

/// The canonical agent handle (`KT_<KIND>_<WORD_WORD_WORD>`): a friendly word
/// code over a 24-bit hash of the id, so it does NOT carry the id. Recovering
/// the UUID needs the set of handles that exist — `resolveAgentHandle(_:among:)`
/// — and the candidate-less `resolveAgentHandle(_:)` only understands the
/// legacy 32-hex form and bare UUIDs. That asymmetry is the contract these
/// tests pin; forgetting it is how a produced OTB became "unreadable" with its
/// bytes on disk.
struct KTResourceManifestHandleTests {
    @Test("agentHandle is KT_<KIND>_ plus the id's three-word token, never a bare UUID")
    func handleShape() {
        let id = UUID(uuidString: "DBEFA918-9977-4C17-A79E-E81306630DDB")!
        let h = KTResourceManifest.agentHandle(kind: .attachment, id: id)
        let token = id.friendlyNameToken.replacingOccurrences(of: "-", with: "_").uppercased()
        #expect(h == "KT_ATTACHMENT_\(token)")
        #expect(token.split(separator: "_").count == 3)
        #expect(!h.contains("-"))
        #expect(h == KTResourceManifest.agentHandle(kind: .attachment, id: id))
    }

    @Test("parseAgentHandleCode recovers the kind and code, and the id among candidates")
    func roundTrips() {
        for kind in [KTResourceManifest.Kind.attachment, .otb, .fs] {
            let id = UUID()
            let handle = KTResourceManifest.agentHandle(kind: kind, id: id)
            let parsed = KTResourceManifest.parseAgentHandleCode(handle)
            #expect(parsed?.kind == kind)
            #expect(parsed?.code == UUIDFriendlyName.code(for: id))
            #expect(
                KTResourceManifest.resolveAgentHandle(handle, among: [id, UUID()]).settledID == id)
        }
    }

    @Test("a leading $ is tolerated and the token is case-insensitive")
    func tolerantParsing() {
        let id = UUID()
        let handle = KTResourceManifest.agentHandle(kind: .otb, id: id)
        #expect(
            KTResourceManifest.parseAgentHandleCode("$" + handle)?.code
                == UUIDFriendlyName.code(for: id))
        // The `KT_<KIND>_` prefix is the fixed part; only the token after it
        // may arrive in whatever case the model typed it.
        let lowercasedToken = "KT_OTB_" + handle.dropFirst("KT_OTB_".count).lowercased()
        #expect(
            KTResourceManifest.resolveAgentHandle(lowercasedToken, among: [id]).settledID == id)
    }

    @Test("parseAgentHandle rejects non-KT and malformed input")
    func rejectsGarbage() {
        #expect(KTResourceManifest.parseAgentHandle(UUID().uuidString) == nil)
        #expect(KTResourceManifest.parseAgentHandle("KT_ATTACHMENT_nothex") == nil)
        #expect(KTResourceManifest.parseAgentHandle("KT_BOGUS_DBEFA91899774C17A79EE81306630DDB") == nil)
        #expect(KTResourceManifest.parseAgentHandle("") == nil)
    }

    @Test("without candidates only bare UUIDs and legacy hex resolve — a word-code handle does not")
    func candidateLessIngest() {
        let id = UUID()
        // The trap: the current handle carries no id, so this MUST be nil. A
        // call site that expects otherwise silently loses every resource.
        #expect(
            KTResourceManifest.resolveAgentHandle(
                KTResourceManifest.agentHandle(kind: .attachment, id: id)) == nil)

        let viaUUID = KTResourceManifest.resolveAgentHandle(id.uuidString.lowercased())
        #expect(viaUUID?.id == id)
        #expect(viaUUID?.kind == nil)  // a bare UUID carries no family

        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        let viaLegacy = KTResourceManifest.resolveAgentHandle("KT_ATTACHMENT_\(hex)")
        #expect(viaLegacy?.id == id)
        #expect(viaLegacy?.kind == .attachment)

        #expect(KTResourceManifest.resolveAgentHandle("not-a-handle") == nil)
    }

    @Test("AgentResource identity init derives the canonical handle; the wire form drops the id")
    func agentResourceInit() throws {
        let id = UUID()
        let r = KTResourceManifest.AgentResource(
            kind: .otb, id: id, direction: "read", name: "photo.jpeg",
            byteCount: 42, origin: "produced")
        #expect(r.handle == KTResourceManifest.agentHandle(kind: .otb, id: id))
        #expect(r.kind == "otb")
        #expect(r.resourceID == id)

        // jsonObject() carries only the handle, so a resource read back out of
        // a tool payload has no resourceID — its id must come from candidates.
        let back = try #require(KTResourceManifest.AgentResource(jsonObject: r.jsonObject()))
        #expect(back.handle == r.handle)
        #expect(back.kind == r.kind)
        #expect(back.name == r.name)
        #expect(back.byteCount == r.byteCount)
        #expect(back.resourceID == nil)
        #expect(KTResourceManifest.resolveAgentHandle(back.handle, among: [id]).settledID == id)
    }

    @Test("write slots are advertised as exact KT env vars")
    func writeSlotPromptContract() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-9DDD-EEEEEEEEEEEE")!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kt-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("result.pdf")
        let manifest = KTResourceManifest.build(
            grantedCandidates: [
                .init(
                    kind: .otb,
                    id: id,
                    path: output,
                    direction: .write,
                    displayName: "result.pdf",
                    isDirectory: false,
                    objectName: "result")
            ],
            umbrellaAttachmentsDir: nil)

        let key = KTResourceManifest.agentHandle(kind: .otb, id: id)
        let path = output.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(manifest.environmentVariables()[key] == path)

        let prompt = try #require(manifest.promptBlock())
        #expect(prompt.contains("$\(key)"))
        #expect(prompt.contains("\"result.pdf\"  write"))
        #expect(prompt.contains("Do not create an unlisted temp path"))
    }
}
