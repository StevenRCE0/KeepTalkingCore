//
//  KTPPWireMessages.swift
//  KeepTalking
//
//  KTPP between KeepTalking and the KT Companion, which owns the plugin socket.
//  Every message is flat JSON with one body key; app messages name the node
//  they speak for (`from`), companion messages the node they are for (`to`).
//

import Foundation
import MCP

public enum KTPPWire {
    public static let protocolVersion = 1
    public static let keepaliveInterval: Duration = .seconds(5)

    public struct AppHello: Codable, Sendable {
        var protocolVersion = KTPPWire.protocolVersion
        var app: String
        var version: String
        var instance: String
    }

    public struct CompanionWelcome: Codable, Sendable {
        var protocolVersion: Int
        var instance: String
    }

    public struct Keepalive: Codable, Sendable {
        var label: String?
    }

    public struct Empty: Codable, Sendable {}

    /// `code` is KTPP's own (`not_connected`, `act_denied`, …).
    public struct Failure: Codable, Sendable, Error {
        var code: String
        var message: String
    }

    public struct CallCancel: Codable, Sendable {
        var requestID: String
    }

    public struct RevealResult: Codable, Sendable {
        var revealed: Bool
    }

    public struct Addressed<Request: Codable & Sendable>: Codable, Sendable {
        var plugin: String
        var request: Request
    }

    public struct CatalogPlugin: Codable, Sendable {
        var name: String
        var vendor: String
        var version: String
        var connected: Bool
        var kinds: KTPPKindsResult?
    }

    public struct Catalog: Codable, Sendable {
        var plugins: [CatalogPlugin]
    }

    public struct AppMessage: Codable, Sendable {
        var id: UInt64?
        var replyTo: UInt64?
        var from: String?
        var hello: AppHello?
        var keepalive: Keepalive?
        var leave: Empty?
        var call: Addressed<KTPPCallRequest>?
        var cancel: CallCancel?
        var scopeOptions: Addressed<KTPPScopeOptionsRequest>?
        var resourceRead: Addressed<KTPPResourceReadRequest>?
        var reveal: Empty?
        var act: KTPPActResult?
        var actionCreate: KTPPActionCreateResult?
        var addAction: Empty?
        var failure: Failure?
    }

    public struct CompanionMessage: Codable, Sendable {
        var id: UInt64?
        var replyTo: UInt64?
        var to: String?
        var welcome: CompanionWelcome?
        var catalog: Catalog?
        var elucidation: KTPPActElucidation?
        var callResult: KTPPCallResult?
        var scopeOptions: KTPPScopeOptionsResult?
        var resourceRead: KTPPResourceReadResult?
        var reveal: RevealResult?
        var act: KTPPActRequest?
        var actionCreate: KTPPActionCreateRequest?
        var addAction: KTPPUIAddActionRequest?
        var failure: Failure?
    }
}
