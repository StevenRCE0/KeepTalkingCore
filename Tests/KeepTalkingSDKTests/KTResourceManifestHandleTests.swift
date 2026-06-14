import Foundation
import Testing

@testable import KeepTalkingSDK

/// Round-trip + ingest-leniency coverage for the canonical agent handle
/// (`KT_<KIND>_<HEX>`) that replaced the former UUID-based `KTAgentResource`.
struct KTResourceManifestHandleTests {
    @Test("agentHandle is the KT_<KIND>_<HEX> shape, never a bare UUID")
    func handleShape() {
        let id = UUID(uuidString: "DBEFA918-9977-4C17-A79E-E81306630DDB")!
        let h = KTResourceManifest.agentHandle(kind: .attachment, id: id)
        #expect(h == "KT_ATTACHMENT_DBEFA91899774C17A79EE81306630DDB")
        #expect(h.hasPrefix("KT_"))
        #expect(!h.contains("-"))
    }

    @Test("parseAgentHandle inverts agentHandle exactly for every kind")
    func roundTrips() {
        for kind in [KTResourceManifest.Kind.attachment, .otb, .fs] {
            let id = UUID()
            let handle = KTResourceManifest.agentHandle(kind: kind, id: id)
            let parsed = KTResourceManifest.parseAgentHandle(handle)
            #expect(parsed?.kind == kind)
            #expect(parsed?.id == id)
        }
    }

    @Test("parseAgentHandle tolerates a leading $ and is case-insensitive on the token")
    func tolerantParsing() {
        let id = UUID()
        let handle = KTResourceManifest.agentHandle(kind: .otb, id: id)
        #expect(KTResourceManifest.parseAgentHandle("$" + handle)?.id == id)
    }

    @Test("parseAgentHandle rejects non-KT and malformed input")
    func rejectsGarbage() {
        #expect(KTResourceManifest.parseAgentHandle(UUID().uuidString) == nil)
        #expect(KTResourceManifest.parseAgentHandle("KT_ATTACHMENT_nothex") == nil)
        #expect(KTResourceManifest.parseAgentHandle("KT_BOGUS_DBEFA91899774C17A79EE81306630DDB") == nil)
        #expect(KTResourceManifest.parseAgentHandle("") == nil)
    }

    @Test("resolveAgentHandle accepts both KT handles and bare UUIDs")
    func lenientIngest() {
        let id = UUID()
        let kt = KTResourceManifest.agentHandle(kind: .attachment, id: id)
        let viaKT = KTResourceManifest.resolveAgentHandle(kt)
        #expect(viaKT?.id == id)
        #expect(viaKT?.kind == .attachment)

        let viaUUID = KTResourceManifest.resolveAgentHandle(id.uuidString.lowercased())
        #expect(viaUUID?.id == id)
        #expect(viaUUID?.kind == nil)  // a bare UUID carries no family

        #expect(KTResourceManifest.resolveAgentHandle("not-a-handle") == nil)
    }

    @Test("AgentResource identity init derives the canonical handle")
    func agentResourceInit() {
        let id = UUID()
        let r = KTResourceManifest.AgentResource(
            kind: .otb, id: id, direction: "read", name: "photo.jpeg",
            byteCount: 42, origin: "produced")
        #expect(r.handle == KTResourceManifest.agentHandle(kind: .otb, id: id))
        #expect(r.kind == "otb")
        // jsonObject round-trips through init?(jsonObject:)
        let back = KTResourceManifest.AgentResource(jsonObject: r.jsonObject())
        #expect(back == r)
        // and the handle still resolves to the original id
        #expect(KTResourceManifest.resolveAgentHandle(back!.handle)?.id == id)
    }
}
