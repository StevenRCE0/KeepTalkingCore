//
//  KeepTalkingActionCall.swift
//  KeepTalking
//
//  Created by 砚渤 on 24/02/2026.
//

import Foundation
import MCP

public struct KeepTalkingActionCall: Codable, Sendable {
    public var action: UUID
    public var arguments: [String: Value]
    public var metadata: Metadata
}
