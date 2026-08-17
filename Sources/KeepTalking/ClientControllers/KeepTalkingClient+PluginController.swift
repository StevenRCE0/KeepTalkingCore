//
//  KeepTalkingClient+PluginController.swift
//  KeepTalking
//
//  Public surface for the Catalogue: enabling the plugin host, browsing the
//  kinds paired plugins provide, and minting action instances from them —
//  the plugin analogue of the primitive creation flow.
//

#if os(macOS)

import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {

    // MARK: Host lifecycle

    /// Starts the KTPP listener. Off by default: a node that never uses
    /// plugins never opens a socket.
    public func enablePluginHost() async throws {
        try await pluginHost.start()
    }

    public func disablePluginHost() async {
        await pluginHost.stop()
    }

    public func setPluginPairingApprovalHandler(
        _ handler: @escaping @Sendable (KTPPPluginInfo, String) async -> Bool
    ) async {
        await pluginHost.setPairingApprovalHandler(handler)
    }

    public func setPluginEventHandler(
        _ handler: (@Sendable (KTPPHostEvent) -> Void)?
    ) async {
        await pluginHost.setEventHandler(handler)
    }

    // MARK: Catalogue

    /// Paired plugin catalogs and their declared kinds — persisted, so this
    /// answers even while every plugin is offline.
    public func pluginCatalogues() async -> [KeepTalkingPluginCatalogueEntry] {
        await pluginHost.catalogue.catalogues()
    }

    /// Every kind a user could instantiate right now, for the Catalogue group
    /// in the action-creation UI. The direct analogue of
    /// `KeepTalkingClient.availablePrimitiveActions`.
    public func availablePluginKinds() async -> [KeepTalkingPluginActionKindSummary] {
        await pluginHost.catalogue.availableKinds()
    }

    public func pluginKindSummary(
        catalogID: UUID, kindName: String
    ) async -> KeepTalkingPluginActionKindSummary? {
        await pluginHost.catalogue.summary(catalogID: catalogID, kindName: kindName)
    }

    // MARK: Instantiation

    /// Mints a persistent action instance from a Catalogue kind and registers
    /// it on this node — the Catalogue equivalent of creating a primitive
    /// action. The instance is inert until granted, exactly like every other
    /// newly created action.
    @discardableResult
    public func instantiatePluginAction(
        catalogID: UUID,
        kindName: String,
        name: String? = nil,
        scope: [String: Value]? = nil,
        node: KeepTalkingNode
    ) async throws -> KeepTalkingAction {
        let bundle = try await pluginHost.makeInstanceBundle(
            catalogID: catalogID, kindName: kindName, name: name, scope: scope)
        let summary = await pluginHost.catalogue.summary(
            catalogID: catalogID, kindName: kindName)
        return try await Self.registerAction(
            payload: .plugin(bundle),
            remoteAuthorisable: summary?.remoteAuthorisable ?? true,
            blockingAuthorisation: bundle.blockingAuthorisation,
            node: node,
            on: localStore.database
        )
    }

    /// Updates the scope bag of an existing Catalogue instance. Rewriting the
    /// bag changes what future calls bind into their signed authorization, so
    /// past receipts stay attributable to the boundary that was in force.
    public func updatePluginActionScope(
        actionID: UUID,
        scope: [String: Value]?
    ) async throws {
        guard
            let action = try await KeepTalkingAction.find(
                actionID, on: localStore.database)
        else { throw KeepTalkingClientError.missingAction }
        guard case .plugin(var bundle) = action.payload else {
            throw KTPPHostError.protocolViolation("action is not a Catalogue instance")
        }
        bundle.scope = scope
        action.payload = .plugin(bundle)
        try await action.save(on: localStore.database)
    }

    /// Removes a Catalogue instance and its grants. There is no executor to
    /// unregister — the plugin process is untouched and keeps serving its other
    /// instances.
    public func removePluginAction(actionID: UUID) async throws {
        let node = try await getCurrentNodeInstance()
        try await Self.removeMCPAction(
            actionID: actionID,
            node: node,
            on: localStore.database,
            callbackForUnregisteringAction: nil
        )
        await invalidateActionToolCatalog(
            reason: "remove_plugin_action action=\(actionID.uuidString.lowercased())"
        )
        await broadcastLocalNodeState(
            reason: "remove_plugin_action action=\(actionID.uuidString.lowercased())"
        )
    }

    /// Forgets a paired plugin catalog and its kinds. Instances already minted
    /// from those kinds are NOT deleted — they are separate rows the user
    /// created, so removing them stays an explicit, separate decision.
    public func forgetPluginCatalogue(_ catalogID: UUID) async {
        await pluginHost.catalogue.removeCatalog(catalogID)
    }

    /// Bridges plugin-initiated proposals (`host.action.create`) to a
    /// confirmation UI. The closure receives the proposal and returns the
    /// created action id, or nil when the user declines.
    public func setPluginActionProposalHandler(
        _ handler: (@Sendable (KeepTalkingPluginActionProposal) async -> UUID?)?
    ) async {
        await pluginHost.setActionProposalHandler(handler)
    }
}

#endif
