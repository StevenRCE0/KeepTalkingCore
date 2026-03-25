import FluentKit
import Foundation

public struct KeepTalkingContextAttachmentMetadata: Codable, Sendable,
    Equatable
{
    public var textPreview: String?
    public var imageDescription: String?
    public var tags: [String]
    public var width: Int?
    public var height: Int?
    public var pageCount: Int?

    public init(
        textPreview: String? = nil,
        imageDescription: String? = nil,
        tags: [String] = [],
        width: Int? = nil,
        height: Int? = nil,
        pageCount: Int? = nil
    ) {
        self.textPreview = textPreview
        self.imageDescription = imageDescription
        self.tags = tags
        self.width = width
        self.height = height
        self.pageCount = pageCount
    }
}

public struct KeepTalkingLocalAttachmentInput: Sendable, Equatable {
    public let sourceURL: URL
    public let filename: String?
    public let mimeType: String?

    public init(
        sourceURL: URL,
        filename: String? = nil,
        mimeType: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.filename = filename
        self.mimeType = mimeType
    }
}

public struct KeepTalkingContextAttachmentDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let contextID: UUID
    public let parentMessageID: UUID
    public let blobID: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let sortIndex: Int

    public init(
        id: UUID,
        contextID: UUID,
        parentMessageID: UUID,
        blobID: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        sortIndex: Int
    ) {
        self.id = id
        self.contextID = contextID
        self.parentMessageID = parentMessageID
        self.blobID = blobID
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = max(byteCount, 0)
        self.sortIndex = sortIndex
    }

    public init?(_ attachment: KeepTalkingContextAttachment) {
        let contextID = attachment.$context.id
        guard
            let id = attachment.id,
            let parentMessageID = attachment.$parentMessage.id
        else {
            return nil
        }

        self.init(
            id: id,
            contextID: contextID,
            parentMessageID: parentMessageID,
            blobID: attachment.blobID,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount,
            sortIndex: attachment.sortIndex
        )
    }

    func makeModel(
        in context: KeepTalkingContext,
        parentMessage: KeepTalkingContextMessage
    ) -> KeepTalkingContextAttachment {
        KeepTalkingContextAttachment(
            id: id,
            context: context,
            parentMessageID: parentMessage.id ?? parentMessageID,
            sender: parentMessage.sender,
            blobID: blobID,
            filename: filename,
            mimeType: mimeType,
            byteCount: byteCount,
            createdAt: parentMessage.timestamp,
            sortIndex: sortIndex
        )
    }
}

public final class KeepTalkingContextAttachment: Model, @unchecked Sendable {
    public static let schema = "kt_context_attachments"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "context")
    public var context: KeepTalkingContext

    @OptionalParent(key: "parent_message")
    public var parentMessage: KeepTalkingContextMessage?

    @Field(key: "sender")
    public var sender: KeepTalkingContextMessage.Sender

    @Field(key: "blob_id")
    public var blobID: String

    @Field(key: "filename")
    public var filename: String

    @Field(key: "mime_type")
    public var mimeType: String

    @Field(key: "byte_count")
    public var byteCount: Int

    @Field(key: "created_at")
    public var createdAt: Date

    @Field(key: "sort_index")
    public var sortIndex: Int

    @Field(key: "metadata")
    public var metadata: KeepTalkingContextAttachmentMetadata

    public init() {}

    public init(
        id: UUID = UUID(),
        context: KeepTalkingContext,
        parentMessageID: UUID? = nil,
        sender: KeepTalkingContextMessage.Sender,
        blobID: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        createdAt: Date = Date(),
        sortIndex: Int = 0,
        metadata: KeepTalkingContextAttachmentMetadata = .init()
    ) {
        self.id = id
        self.$context.id = context.id!
        self.$parentMessage.id = parentMessageID
        self.sender = sender
        self.blobID = blobID
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.metadata = metadata
    }
}

extension KeepTalkingContextAttachment {
    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
}
