//
//  NodeRelation.swift
//  KeepTalking
//
//  Created by 砚渤 on 23/02/2026.
//

import FluentKit
import Foundation

public enum KeepTalkingRelationship: Codable, Sendable, Equatable {
    case pending
    case preTrusted([KeepTalkingContext])
    case owner
    case trusted([KeepTalkingContext])
    case trustedInAllContext

    public var isTrustedOrOwner: Bool {
        switch self {
            case .owner, .trusted, .trustedInAllContext:
                return true
            case .pending, .preTrusted:
                return false
        }
    }

    public func allows(context: KeepTalkingContext?) -> Bool {
        switch self {
            case .owner, .trustedInAllContext:
                return true
            case .trusted(let contexts):
                guard let context else { return false }
                return contexts.contains(context)
            case .pending, .preTrusted:
                return false
        }
    }

    public func allowsGrantStaging(context: KeepTalkingContext?) -> Bool {
        switch self {
            case .owner, .trustedInAllContext:
                return true
            case .trusted:
                // Trusted elsewhere: the pending invitation can't be folded
                // into a trusted relation the way `.preTrusted` folds it, so
                // any context stages. The grant stays inert until the
                // handshake extends trust here — execution asks `allows`.
                return context != nil
            case .preTrusted(let contexts):
                guard let context else { return false }
                return contexts.contains(context)
            case .pending:
                return false
        }
    }
}

public enum KeepTalkingRelationEligibility: Sendable {
    case trustedOnly
    case grantStaging
}

public final class KeepTalkingNodeRelation: Model, @unchecked Sendable {
    public static let schema = "kt_node_relation"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "relationship")
    public var relationship: KeepTalkingRelationship

    @Parent(key: "from")
    public var from: KeepTalkingNode

    @Parent(key: "to")
    public var to: KeepTalkingNode

    @Children(for: \.$relation)
    public var actionRelations: [KeepTalkingNodeRelationActionRelation]

    @Siblings(
        through: KeepTalkingNodeRelationAliasRelation.self,
        from: \.$relation,
        to: \.$alias
    )
    public var aliases: [KeepTalkingMapping]

    @Children(for: \.$relation)
    public var identityKeys: [KeepTalkingNodeIdentityKey]

    public init() {
        relationship = .pending
    }

    public init(
        id: UUID = UUID.v7(),
        from: KeepTalkingNode,
        to: KeepTalkingNode,
        relationship: KeepTalkingRelationship,
    ) throws {
        self.id = id
        self.$from.id = try from.requireID()
        self.$to.id = try to.requireID()
        self.relationship = relationship
    }

    public func allows(context: KeepTalkingContext?) -> Bool {
        relationship.allows(context: context)
    }
}

extension KeepTalkingRelationship {
    public var priority: Int {
        switch self {
            case .owner: 4
            case .trustedInAllContext: 3
            case .trusted: 2
            case .preTrusted: 1
            case .pending: 0
        }
    }
}

/// A pair may hold rows of several kinds, and nothing in the schema stops a
/// race from adding one more. Every read here is strongest first, so a pair
/// with several rows answers the same way on every read.
extension KeepTalkingNodeRelation {
    public convenience init(
        id: UUID = UUID.v7(),
        fromID: UUID,
        toID: UUID,
        relationship: KeepTalkingRelationship
    ) {
        self.init()
        self.id = id
        self.$from.id = fromID
        self.$to.id = toID
        self.relationship = relationship
    }

    public static func strongestFirst(
        _ relations: [KeepTalkingNodeRelation]
    ) -> [KeepTalkingNodeRelation] {
        relations.sorted {
            let lhs = $0.relationship.priority
            let rhs = $1.relationship.priority
            return lhs == rhs
                ? ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
                : lhs > rhs
        }
    }

    public static func rows(
        from fromID: UUID,
        to toID: UUID,
        on database: any Database
    ) async throws -> [KeepTalkingNodeRelation] {
        strongestFirst(
            try await query(on: database)
                .filter(\.$from.$id == fromID)
                .filter(\.$to.$id == toID)
                .all()
        )
    }

    public static func strongest(
        from fromID: UUID,
        to toID: UUID,
        on database: any Database
    ) async throws -> KeepTalkingNodeRelation? {
        try await rows(from: fromID, to: toID, on: database).first
    }

    @discardableResult
    public static func firstOrCreate(
        from fromID: UUID,
        to toID: UUID,
        initial: KeepTalkingRelationship,
        accepting accepts: @escaping @Sendable (KeepTalkingRelationship) -> Bool = { _ in true },
        on database: any Database
    ) async throws -> KeepTalkingNodeRelation {
        try await firstOrCreate(
            on: database,
            matching: { $0.filter(\.$from.$id == fromID).filter(\.$to.$id == toID) },
            choosing: { strongestFirst($0).first { accepts($0.relationship) } },
            create: { KeepTalkingNodeRelation(fromID: fromID, toID: toID, relationship: initial) }
        )
    }
}
