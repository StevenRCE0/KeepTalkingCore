//
//  KeepTalkingActionType.swift
//  KeepTalking
//
//  Created by 砚渤 on 13/10/2026.
//

import Foundation

public enum KeepTalkingActionType: String, CaseIterable, Identifiable, Hashable {
    case http = "HTTP"
    case stdio = "STDIO"
    case skill = "Skill"
    case primitive = "Primitive"
    case shortcut = "Shortcut"
    case filesystem = "Filesystem"
    case acp = "ACP"
    /// Kinds contributed by paired plugins — the Catalogue group.
    case catalogue = "Catalogue"

    public var id: Self { self }

    public var icon: String {
        switch self {
            case .http: "network"
            case .stdio: "terminal"
            case .skill: "text.document"
            case .primitive: "bolt.fill"
            case .shortcut: "square.2.layers.3d.bottom.filled"
            case .filesystem: "folder.fill"
            case .acp: "wand.and.rays"
            case .catalogue: "heart.square.fill"
        }
    }

    public var shortDescription: String {
        switch self {
            case .http: "Connect to an MCP server over HTTP or HTTPS"
            case .stdio: "Run a local process via standard I/O"
            case .skill: "Load a skill bundle from a local folder"
            case .primitive: "Built-in system capabilities"
            case .shortcut: "Run a macOS Shortcut by name"
            case .filesystem: "Expose a local filesystem path"
            case .acp: "Delegate tasks to an external coding agent (ACP)"
            case .catalogue: "Ready-made actions from plugins in your Companion"
        }
    }
}
