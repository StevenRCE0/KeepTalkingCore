import Foundation
import Testing

@testable import KeepTalkingSDK

/// Properties `friendlyName` has to hold, not just happen to have today.
///
/// The old implementation indexed straight into the UUID's bytes. Because
/// KeepTalking mints v7 UUIDs — leading 48 bits are a millisecond timestamp —
/// the adjective only changed every 49.7 days and the noun cycled every 4.66
/// hours. On 220 real ids that produced 165 distinct names, one of them shared
/// by 15 objects. `spreadOverRealisticV7Ids` is the regression for that.
struct UUIDFriendlyNameTests {

    // MARK: - Word lists

    @Test("word lists are well formed and single-typo safe")
    func friendlyNameWordListsAreWellFormed() {
        for (label, list) in [
            ("adjectives", UUIDFriendlyName.adjectives),
            ("nouns", UUIDFriendlyName.nouns),
        ] {
            #expect(list.count == 256, "\(label) must be exactly 256 for byte indexing")
            #expect(Set(list).count == list.count, "\(label) has duplicates")

            for word in list {
                #expect(
                    word.allSatisfy { $0.isLowercase && $0.isLetter },
                    "\(label) entry '\(word)' must be one lowercase word")
            }

            // The property the repair path depends on: no single edit turns one
            // list word into another, so a typo is always attributable.
            var offenders: [String] = []
            for i in list.indices {
                for j in (i + 1)..<list.count
                where UUIDFriendlyName.isWithinOneEdit(list[i], list[j]) {
                    offenders.append("\(list[i])/\(list[j])")
                }
            }
            #expect(offenders.isEmpty, "\(label) pairs within one edit: \(offenders)")
        }
    }

    // MARK: - Derivation

    @Test("names are stable for the same id")
    func namesAreStable() {
        let id = UUID()
        #expect(id.friendlyName == id.friendlyName)
        #expect(id.friendlyNameToken == id.friendlyNameToken)
    }

    @Test("a name is three words, displayed capitalised and matched lowercase")
    func friendlyNameShape() {
        let id = UUID()
        #expect(id.friendlyName.split(separator: " ").count == 3)
        #expect(
            id.friendlyNameToken
                == id.friendlyName.lowercased()
                .replacingOccurrences(of: " ", with: "-"))

        let parts = UUID().friendlyNameToken.split(separator: "-").map(String.init)
        #expect(parts.count == 3)
        #expect(UUIDFriendlyName.adjectives.contains(parts[0]))
        #expect(UUIDFriendlyName.adjectives.contains(parts[1]))
        #expect(UUIDFriendlyName.nouns.contains(parts[2]))
    }

    /// The actual regression. v7 ids minted seconds apart used to collapse onto
    /// the same words; they must now spread across the full list.
    @Test("names spread across ids minted seconds apart, as v7 ids really are")
    func spreadOverRealisticV7Ids() {
        // Same 48-bit timestamp prefix ticking forward, exactly the shape the
        // old byte-slicing implementation degenerated on.
        var ids: [UUID] = []
        for tick in 0..<500 {
            let ms = UInt64(0x0192_ABCD_0000) &+ UInt64(tick &* 997)
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
            bytes[6] = 0x70 | UInt8(tick & 0x0F)
            bytes[7] = UInt8((tick >> 4) & 0xFF)
            bytes[8] = 0x80
            for i in 9..<16 { bytes[i] = UInt8((tick &* (i &+ 7)) & 0xFF) }
            ids.append(
                UUID(
                    uuid: (
                        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                        bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                        bytes[12], bytes[13], bytes[14], bytes[15]
                    )))
        }

        let names = Set(ids.map(\.friendlyNameToken))
        #expect(
            names.count == ids.count,
            "500 v7 ids produced only \(names.count) distinct names")

        // The display form carries the same three words, so it is equally distinct.
        #expect(Set(ids.map(\.friendlyName)).count == ids.count)

        // And the words must not be stuck on a handful of list entries.
        let firstWords = Set(ids.map { $0.friendlyNameToken.split(separator: "-")[0] })
        #expect(firstWords.count > 100, "first word barely varies: \(firstWords.count)")
    }

    // MARK: - Resolving a name someone typed back

    @Test("an exact mnemonic resolves")
    func exactMnemonicResolves() {
        let id = UUID()
        let other = UUID()
        #expect(
            UUIDFriendlyName.resolve(id.friendlyNameToken, among: [id, other]) == .resolved(id))
    }

    @Test("a raw UUID still resolves, so old callers keep working")
    func rawUUIDStillResolves() {
        let id = UUID()
        #expect(
            UUIDFriendlyName.resolve(id.uuidString, among: [id]) == .resolved(id))
        #expect(
            UUIDFriendlyName.resolve(id.uuidString.lowercased(), among: [id])
                == .resolved(id))
    }

    @Test("one mistyped letter is repaired to the intended action")
    func singleTypoIsRepaired() throws {
        let id = UUID()
        var words = id.friendlyNameToken.split(separator: "-").map(String.init)
        // Corrupt one letter of the last word, the way a model drops a character.
        let victim = words[2]
        words[2] = String(victim.dropLast()) + (victim.hasSuffix("a") ? "e" : "a")
        let mistyped = words.joined(separator: "-")
        try #require(mistyped != id.friendlyNameToken)

        guard
            case .corrected(let resolved, _, let to) =
                UUIDFriendlyName.resolve(mistyped, among: [id])
        else {
            Issue.record("expected a repair, got \(UUIDFriendlyName.resolve(mistyped, among: [id]))")
            return
        }
        #expect(resolved == id)
        #expect(to == id.friendlyNameToken)
    }

    @Test("formatting differences are tolerated, not treated as typos")
    func separatorsAndCaseAreTolerated() {
        let id = UUID()
        let spaced = id.friendlyNameToken.replacingOccurrences(of: "-", with: " ")
        let underscored = id.friendlyNameToken.replacingOccurrences(of: "-", with: "_")
        #expect(UUIDFriendlyName.resolve(spaced, among: [id]) == .resolved(id))
        #expect(UUIDFriendlyName.resolve(underscored, among: [id]) == .resolved(id))
        #expect(
            UUIDFriendlyName.resolve(id.friendlyNameToken.uppercased(), among: [id])
                == .resolved(id))
    }

    @Test("an unrelated phrase resolves to nothing rather than a wrong action")
    func unrelatedPhraseIsUnknown() {
        // Guessing here would be worse than failing: it would silently run a
        // different action than the agent asked for.
        #expect(
            UUIDFriendlyName.resolve("zzzzz-qqqqq-xxxxx", among: [UUID()])
                == .unknown)
    }

    @Test("a mistyped hex id is never repaired")
    func hexIsNeverGuessed() {
        // Hex has no redundancy — a near-miss UUID could legitimately be any
        // other id, so repair would be reckless.
        let id = try! #require(UUID(uuidString: "019EBBD5-8D87-7000-946E-76135023BD00"))
        let mistyped = "019ebbd5-8d87-7000-946b-76135023bd00"
        #expect(UUIDFriendlyName.resolve(mistyped, among: [id]) == .unknown)
    }
}

/// The name ↔ code bijection.
///
/// `UUID -> Code` is a hash and therefore lossy — 128 bits do not fit in 24.
/// That loss is unavoidable and confined to exactly that one step. Everything
/// after it must be exact: a code and its printed name are one value in two
/// spellings, and converting either way must never lose or invent anything.
struct FriendlyNameCodeTests {

    typealias Code = UUIDFriendlyName.Code

    @Test("every code round-trips through its name, in both spellings")
    func everyCodeRoundTrips() throws {
        // Exhaustive over each word position independently — 256 values in each
        // of three slots, with a mixed sweep too, covers every word in every
        // position without building 16.7M strings.
        for i in 0..<256 {
            for code in [
                try #require(Code(first: i, second: 0, third: 0)),
                try #require(Code(first: 0, second: i, third: 0)),
                try #require(Code(first: 0, second: 0, third: i)),
                try #require(Code(first: i, second: 255 - i, third: i)),
            ] {
                #expect(Code(name: code.name) == code)
                #expect(Code(name: code.token) == code)
            }
        }
    }

    @Test("a large random sample round-trips exactly")
    func randomSampleRoundTrips() throws {
        for _ in 0..<20_000 {
            let raw = Int.random(in: 0..<Code.space)
            let code = try #require(Code(rawValue: raw))
            #expect(Code(name: code.name)?.rawValue == raw)
            #expect(Code(name: code.token)?.rawValue == raw)
        }
    }

    @Test("distinct codes never share a name")
    func distinctCodesHaveDistinctNames() throws {
        // Injective in the direction that matters: if two names are equal the
        // codes must be too, or "same name" would stop meaning "same code".
        var seen: [String: Int] = [:]
        for raw in stride(from: 0, to: Code.space, by: 977) {
            let code = try #require(Code(rawValue: raw))
            if let prior = seen.updateValue(raw, forKey: code.token) {
                Issue.record("codes \(prior) and \(raw) both print '\(code.token)'")
                return
            }
        }
    }

    @Test("the two spellings agree")
    func spellingsAgree() throws {
        let code = try #require(Code(first: 7, second: 200, third: 42))
        #expect(code.token == code.name.lowercased().replacingOccurrences(of: " ", with: "-"))
        #expect(Code(name: code.name) == Code(name: code.token))
    }

    @Test("a name with a word outside the lists does not decode")
    func unknownWordDoesNotDecode() {
        // Detectably corrupt, rather than silently decoding to something wrong.
        #expect(Code(name: "amber-swift-notaword") == nil)
        #expect(Code(name: "amber-swift") == nil)
        #expect(Code(name: "amber-swift-koala-extra") == nil)
        #expect(Code(name: "") == nil)
    }

    @Test("codes outside the space are rejected")
    func outOfRangeCodesRejected() {
        #expect(Code(rawValue: -1) == nil)
        #expect(Code(rawValue: Code.space) == nil)
        #expect(Code(rawValue: Code.space - 1) != nil)
        #expect(Code(first: 256, second: 0, third: 0) == nil)
    }

    @Test("a UUID's name and code are the same value")
    func uuidNameAndCodeAgree() {
        let id = UUID()
        #expect(id.friendlyName == id.friendlyNameCode.name)
        #expect(id.friendlyNameToken == id.friendlyNameCode.token)
        #expect(Code(name: id.friendlyName) == id.friendlyNameCode)
    }

    @Test("two objects share a name exactly when they share a code")
    func nameIdentityIsCodeIdentity() {
        // This is what makes the code the right thing to store or index on.
        let ids = (0..<40).map { _ in UUID() }
        for a in ids {
            for b in ids {
                #expect(
                    (a.friendlyName == b.friendlyName)
                        == (a.friendlyNameCode == b.friendlyNameCode))
            }
        }
    }
}
