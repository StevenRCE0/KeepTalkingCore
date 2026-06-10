import Foundation
import UUIDV7

extension UUID {
    /// Generates a time-ordered UUIDv7 (RFC 9562) as a Foundation `UUID`.
    ///
    /// Used for default primary-key generation on newly created entities so
    /// that IDs sort by creation time — better B-tree index locality and a
    /// natural chronological ordering — while remaining standard, fully random
    /// 128-bit-storage UUIDs. ID columns stay plain `UUID`; nothing validates or
    /// requires a specific version, so existing persisted IDs (any version) are
    /// read back unchanged. Only fresh-record generation paths call this.
    ///
    /// Sequential calls are monotonically increasing, matching `UUIDV7()`'s
    /// guarantee.
    public static func v7() -> UUID {
        UUIDV7().rawValue
    }
}
