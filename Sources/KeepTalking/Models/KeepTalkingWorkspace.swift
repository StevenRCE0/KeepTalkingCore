import Foundation

public enum KeepTalkingWorkspaceKind: String, Codable, Sendable, Equatable {
    case canvas
    case document
    case timeline
    case board
    case map
    case custom
}

public enum KeepTalkingWorkspaceGranularity: String, Codable, Sendable, Comparable, CaseIterable {
    case selection
    case viewport
    case full

    private var rank: Int {
        switch self {
            case .selection: return 0
            case .viewport: return 1
            case .full: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct KeepTalkingWorkspaceStats: Codable, Sendable, Equatable {
    public var totalElements: Int
    public var visibleElements: Int
    public var selectedElements: Int
    public var groups: Int
    public var connections: Int

    public init(
        totalElements: Int = 0,
        visibleElements: Int = 0,
        selectedElements: Int = 0,
        groups: Int = 0,
        connections: Int = 0
    ) {
        self.totalElements = totalElements
        self.visibleElements = visibleElements
        self.selectedElements = selectedElements
        self.groups = groups
        self.connections = connections
    }

    public var summaryLine: String {
        "\(totalElements) elements, \(visibleElements) visible, \(selectedElements) selected, \(groups) groups, \(connections) connections"
    }
}

public struct KeepTalkingWorkspaceSnapshot: Codable, Sendable, Equatable {
    public var granularity: KeepTalkingWorkspaceGranularity
    public var timestamp: Date
    public var stats: KeepTalkingWorkspaceStats
    public var liftedText: String

    public init(
        granularity: KeepTalkingWorkspaceGranularity,
        timestamp: Date = Date(),
        stats: KeepTalkingWorkspaceStats,
        liftedText: String
    ) {
        self.granularity = granularity
        self.timestamp = timestamp
        self.stats = stats
        self.liftedText = liftedText
    }
}

public struct KeepTalkingWorkspaceManifest: Codable, Sendable, Equatable {
    public var title: String
    public var kind: KeepTalkingWorkspaceKind
    public var schema: String
    public var granularities: [KeepTalkingWorkspaceGranularity]
    public var mutations: [String]
    public var mutationGuide: String?

    public init(
        title: String,
        kind: KeepTalkingWorkspaceKind,
        schema: String,
        granularities: [KeepTalkingWorkspaceGranularity],
        mutations: [String] = [],
        mutationGuide: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.schema = schema
        self.granularities = granularities
        self.mutations = mutations
        self.mutationGuide = mutationGuide
    }
}

public struct KeepTalkingWorkspaceMutation: Codable, Sendable, Equatable {
    public var operation: String
    public var payloadJSON: String
    public var targetElementID: String?
}

public struct KeepTalkingWorkspaceMutationResult: Codable, Sendable, Equatable {
    public var applied: Int
    public var failed: Int
    public var createdElementIDs: [String]
    public var errors: [String]

    public init(applied: Int, failed: Int, createdElementIDs: [String] = [], errors: [String] = []) {
        self.applied = applied
        self.failed = failed
        self.createdElementIDs = createdElementIDs
        self.errors = errors
    }
}

public enum KeepTalkingWorkspaceError: Error, LocalizedError {
    case readOnly(schema: String)
    case noWorkspace(schema: String?)
    case noExport(schema: String)
    case resourceNotFound(String)
    case resourceNotReady(String)
    case resourceUnsupported(String, mimeType: String)

    public var errorDescription: String? {
        switch self {
            case .readOnly(let schema): return "The \(schema) workspace accepts no mutations."
            case .noExport(let schema): return "The \(schema) workspace cannot export its state."
            case .noWorkspace(let schema):
                return schema.map { "No open workspace with schema \($0)." } ?? "No open workspace."
            case .resourceNotFound(let handle): return "No attachment \(handle) in this context."
            case .resourceNotReady(let handle): return "Attachment \(handle) has not arrived on this node yet."
            case .resourceUnsupported(let handle, let mimeType):
                return "Attachment \(handle) is \(mimeType); only images can go into a workspace."
        }
    }
}

public struct KeepTalkingWorkspaceResource: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var dataURL: String

    public static let imageTarget = KeepTalkingImageEncodingTarget(
        maxPixelSize: 2048,
        maxBytes: 6 * 1024 * 1024,
        acceptedMIMETypes: AIImageInputPolicy.commonMIMETypes
    )

    public var jsonObject: [String: Any] {
        ["id": id.uuidString.lowercased(), "name": name, "mimeType": mimeType, "dataURL": dataURL]
    }
}

public struct KeepTalkingWorkspaceSection: Sendable, Equatable {
    public var manifest: KeepTalkingWorkspaceManifest
    public var snapshot: KeepTalkingWorkspaceSnapshot
}

public protocol KeepTalkingWorkspaceProviding: Sendable {
    var manifest: KeepTalkingWorkspaceManifest { get }
    func snapshot(granularity: KeepTalkingWorkspaceGranularity) async throws -> KeepTalkingWorkspaceSnapshot
    func applyMutations(_ mutations: [KeepTalkingWorkspaceMutation]) async throws -> KeepTalkingWorkspaceMutationResult
    func export() async throws -> KeepTalkingWorkspaceExport
}

extension KeepTalkingWorkspaceProviding {
    public func applyMutations(_ mutations: [KeepTalkingWorkspaceMutation]) async throws
        -> KeepTalkingWorkspaceMutationResult
    {
        throw KeepTalkingWorkspaceError.readOnly(schema: manifest.schema)
    }

    public func export() async throws -> KeepTalkingWorkspaceExport {
        throw KeepTalkingWorkspaceError.noExport(schema: manifest.schema)
    }
}

public struct KeepTalkingWorkspacePromptPolicy: Sendable, Equatable {
    public var totalTokenBudget = 4000

    public static let `default` = KeepTalkingWorkspacePromptPolicy()

    public func perProviderBudget(providerCount: Int) -> Int {
        guard providerCount > 0 else { return totalTokenBudget }
        return totalTokenBudget / providerCount
    }
}

public struct KeepTalkingWorkspaceViewport: Codable, Sendable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    public var selectedElementIDs: [String]
    public var timestamp: UInt64

    public init(centerX: Double, centerY: Double, zoom: Double, selectedElementIDs: [String] = [], timestamp: UInt64) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
        self.selectedElementIDs = selectedElementIDs
        self.timestamp = timestamp
    }
}

public struct KeepTalkingWorkspaceExport: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    public var pathExtension: String

    public init(data: Data, mimeType: String, pathExtension: String) {
        self.data = data
        self.mimeType = mimeType
        self.pathExtension = pathExtension
    }
}

public enum KeepTalkingWorkspaceFollowMode: Sendable, Equatable {
    case free
    case broadcasting
    case following(UUID)
}

public struct KeepTalkingWorkspaceStage: Codable, Sendable, Equatable {
    public var schema: String
    public var holder: UUID
    public var blobID: String
    public var mimeType: String
    public var updatedAt = Date()
}

public struct KeepTalkingWorkspacePendingStage: Sendable, Equatable {
    public let stage: KeepTalkingWorkspaceStage
    public let data: Data
}

public struct KeepTalkingWorkspaceChange: Sendable, Equatable {
    public let contextID: UUID
    public let schema: String
    public let origin: UUID
    public let change: Data
}

public struct KeepTalkingWorkspaceViewportUpdate: Sendable, Equatable {
    public let contextID: UUID
    public let schema: String
    public let from: UUID
    public let state: KeepTalkingWorkspaceViewport
}

public struct KeepTalkingContextWorkspaceRecord: Codable, Sendable, Equatable, Identifiable {
    public var schema: String
    public var title: String
    public var kind: KeepTalkingWorkspaceKind
    public var provider: String
    public var addedBy: UUID
    public var updatedAt = Date()
    public var isRemoved = false

    public var id: String { schema }
}
