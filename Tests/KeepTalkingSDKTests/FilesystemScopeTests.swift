import Foundation
import Testing

@testable import KeepTalkingSDK

struct FilesystemScopeTests {

    @Test("filesystem operation → required structural verb")
    func requiredVerbMapping() {
        #expect(KeepTalkingFilesystemOperation.ls.requiredVerb == .ls)
        #expect(KeepTalkingFilesystemOperation.grep.requiredVerb == .grep)
        #expect(KeepTalkingFilesystemOperation.readFile.requiredVerb == .read)
        #expect(KeepTalkingFilesystemOperation.stat.requiredVerb == .read)
        #expect(KeepTalkingFilesystemOperation.getFile.requiredVerb == .read)
        #expect(KeepTalkingFilesystemOperation.writeFile.requiredVerb == .write)
        #expect(KeepTalkingFilesystemOperation.sed.requiredVerb == .write)
        #expect(KeepTalkingFilesystemOperation.putFile.requiredVerb == .write)
    }

    @Test("a read scope permits read-class ops and denies write-class ops")
    func readScopeGate() {
        // Matches the parity mapping: a "read" grant expands to {.read,.ls,.grep}.
        let readScope = KeepTalkingActionScope.verbs([.read, .ls, .grep])
        for op in [KeepTalkingFilesystemOperation.ls, .readFile, .grep, .stat, .getFile] {
            #expect(readScope.allows(op.requiredVerb), "read scope should allow \(op.rawValue)")
        }
        for op in [KeepTalkingFilesystemOperation.writeFile, .sed, .putFile] {
            #expect(!readScope.allows(op.requiredVerb), "read scope should deny \(op.rawValue)")
        }
    }

    @Test("`.all` permits every op; `.verbs([])` permits none and is denied")
    func allAndDenied() {
        for op in KeepTalkingFilesystemOperation.allCases {
            #expect(KeepTalkingActionScope.all.allows(op.requiredVerb))
            #expect(!KeepTalkingActionScope.verbs([]).allows(op.requiredVerb))
        }
        #expect(KeepTalkingActionScope.verbs([]).isDenied)
    }
}
