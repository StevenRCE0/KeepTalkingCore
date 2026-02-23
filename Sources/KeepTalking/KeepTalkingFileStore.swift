import Foundation

public final class KeepTalkingFileStore: KeepTalkingLocalStore, @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "KeepTalking.fileStore")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.fileURL = baseDir
                .appendingPathComponent("KeepTalking", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        }

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadSnapshot() throws -> KeepTalkingLocalSnapshot {
        try queue.sync {
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else {
                return KeepTalkingLocalSnapshot()
            }
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(KeepTalkingLocalSnapshot.self, from: data)
        }
    }

    public func saveSnapshot(_ snapshot: KeepTalkingLocalSnapshot) throws {
        try queue.sync {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
