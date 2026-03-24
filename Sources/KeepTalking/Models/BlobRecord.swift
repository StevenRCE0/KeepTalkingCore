import FluentKit
import Foundation

public enum KeepTalkingBlobAvailability: String, Codable, Sendable,
    CaseIterable
{
    case missing
    case partial
    case ready
}

public final class KeepTalkingBlobRecord: Model, @unchecked Sendable {
    public static let schema = "kt_blob_records"

    @ID(custom: "blob_id", generatedBy: .user)
    public var id: String?

    @OptionalField(key: "relative_path")
    public var relativePath: String?

    @Field(key: "availability")
    public var availability: KeepTalkingBlobAvailability

    @Field(key: "mime_type")
    public var mimeType: String

    @Field(key: "byte_count")
    public var byteCount: Int

    @Field(key: "received_bytes")
    public var receivedBytes: Int

    @OptionalField(key: "last_accessed_at")
    public var lastAccessedAt: Date?

    @OptionalField(key: "ai_described_at")
    public var aiDescribedAt: Date?

    @OptionalField(key: "ai_last_native_include_at")
    public var aiLastNativeIncludeAt: Date?

    public init() {}

    public init(
        blobID: String,
        relativePath: String? = nil,
        availability: KeepTalkingBlobAvailability,
        mimeType: String,
        byteCount: Int,
        receivedBytes: Int,
        lastAccessedAt: Date? = nil,
        aiDescribedAt: Date? = nil,
        aiLastNativeIncludeAt: Date? = nil
    ) {
        id = blobID
        self.relativePath = relativePath
        self.availability = availability
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.receivedBytes = receivedBytes
        self.lastAccessedAt = lastAccessedAt
        self.aiDescribedAt = aiDescribedAt
        self.aiLastNativeIncludeAt = aiLastNativeIncludeAt
    }
}
