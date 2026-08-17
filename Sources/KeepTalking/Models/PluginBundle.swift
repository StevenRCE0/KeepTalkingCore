import Foundation
import MCP

/// An action *instance* minted from a plugin-provided **kind** — the Catalogue
/// analogue of `KeepTalkingPrimitiveBundle`.
///
/// The parallel with primitives is deliberate: a plugin contributes *templates*
/// (kinds, each with a `scopeSchema`), and the user instantiates one into a real
/// `kt_actions` row carrying a concrete scope bag. N instances of one kind can
/// exist side by side, scoped differently and granted separately — "Browser
/// (docs only)" and "Browser (internal wiki)" are two rows, one kind.
///
/// A plugin can never mint one of these itself; only the user (or an
/// explicitly-approved proposal, see `KeepTalkingPluginActionProposal`) can.
public struct KeepTalkingPluginBundle: KeepTalkingActionBundle, Equatable {
    public var id: UUID
    /// User-editable instance label; defaults to the kind's display name.
    public var name: String
    public var indexDescription: String
    /// The paired plugin catalog that provides the kind.
    public var catalogID: UUID
    /// Stable kind key within that catalog.
    public var kindName: String
    /// The user-configured scope bag, validated against the kind's
    /// `scopeSchema` at instantiation. The generalized counterpart of
    /// `KeepTalkingPrimitiveBundle.scope` (which is `[String: [String]]`);
    /// plugin scopes carry arbitrary JSON so a kind can declare booleans,
    /// numbers, or nested objects.
    public var scope: [String: Value]?
    /// Sub-tool of the kind this instance is pinned to, when the kind exposes
    /// several and the user narrowed to one. `nil` = the whole kind.
    public var tool: String?
    public var blockingAuthorisation: Bool

    public init(
        id: UUID = UUID.v7(),
        name: String,
        indexDescription: String = "",
        catalogID: UUID,
        kindName: String,
        scope: [String: Value]? = nil,
        tool: String? = nil,
        blockingAuthorisation: Bool = false
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.catalogID = catalogID
        self.kindName = kindName
        self.scope = scope
        self.tool = tool
        self.blockingAuthorisation = blockingAuthorisation
    }

    /// Mirrors `KeepTalkingPrimitiveBundle.assigningNewID()` — the template →
    /// instance step.
    public func assigningNewID() -> KeepTalkingPluginBundle {
        var copy = self
        copy.id = UUID.v7()
        return copy
    }

    /// The scope bag as a single `Value`, the form the wire protocol and the
    /// signed `instanceScopeHash` use.
    public var scopeValue: Value? {
        guard let scope, !scope.isEmpty else { return nil }
        return .object(scope)
    }
}

/// One plugin-provided action kind as stored by the Catalogue — the template a
/// user instantiates. Flattened from the wire declaration so the app can render
/// a creation form without holding a live session.
public struct KeepTalkingPluginActionKindSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(catalogID.uuidString.lowercased()):\(kindName)" }
    public let catalogID: UUID
    public let catalogName: String
    public let vendor: String
    public let kindName: String
    public let displayName: String
    public let indexDescription: String
    public let inputSchema: Value?
    /// JSON-schema fragments per scope key — drives the creation form, exactly
    /// as `KeepTalkingPrimitiveActionKind.scopeSchema` does for primitives.
    public let scopeSchema: Value?
    public let defaultScope: Value?
    public let subTools: [String]
    public let remoteAuthorisable: Bool
    public let blockingAuthorisation: Bool
    /// Whether the providing catalog currently has a live session. Kinds stay
    /// listed while a plugin is offline (instances and grants outlive it), just
    /// marked unavailable.
    public let isAvailable: Bool

    public init(
        catalogID: UUID,
        catalogName: String,
        vendor: String,
        kindName: String,
        displayName: String,
        indexDescription: String,
        inputSchema: Value? = nil,
        scopeSchema: Value? = nil,
        defaultScope: Value? = nil,
        subTools: [String] = [],
        remoteAuthorisable: Bool = true,
        blockingAuthorisation: Bool = false,
        isAvailable: Bool
    ) {
        self.catalogID = catalogID
        self.catalogName = catalogName
        self.vendor = vendor
        self.kindName = kindName
        self.displayName = displayName
        self.indexDescription = indexDescription
        self.inputSchema = inputSchema
        self.scopeSchema = scopeSchema
        self.defaultScope = defaultScope
        self.subTools = subTools
        self.remoteAuthorisable = remoteAuthorisable
        self.blockingAuthorisation = blockingAuthorisation
        self.isAvailable = isAvailable
    }

    /// Scope keys in stable display order, for form generation.
    public var scopeKeys: [String] {
        guard case .object(let fields)? = scopeSchema else { return [] }
        return fields.keys.sorted()
    }
}

/// A plugin's *request* that the user create an instance of one of its kinds —
/// the companion-initiated half of action creation (`host.action.create`).
///
/// Deliberately a proposal, not a command: it carries suggested values and the
/// host surfaces them for confirmation. Approving mints the instance exactly as
/// the in-app Catalogue flow would; declining is silent.
public struct KeepTalkingPluginActionProposal: Sendable, Identifiable {
    public let id: UUID
    public let catalogID: UUID
    public let catalogName: String
    public let kindName: String
    /// Instance label the plugin suggests; user-editable before approval.
    public let suggestedName: String
    public let reason: String?
    public let suggestedScope: Value?

    public init(
        id: UUID = UUID.v7(),
        catalogID: UUID,
        catalogName: String,
        kindName: String,
        suggestedName: String,
        reason: String? = nil,
        suggestedScope: Value? = nil
    ) {
        self.id = id
        self.catalogID = catalogID
        self.catalogName = catalogName
        self.kindName = kindName
        self.suggestedName = suggestedName
        self.reason = reason
        self.suggestedScope = suggestedScope
    }
}
