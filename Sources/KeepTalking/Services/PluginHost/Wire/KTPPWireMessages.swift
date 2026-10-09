//
//  KTPPWireMessages.swift
//  KeepTalking
//
//  KTPP — the plugin protocol carried over gRPC, with JSON messages and no
//  protobuf (the transport lives in KTPPWireService.swift, desktop builds
//  only). This file holds the typed messages: the two `Connect` envelopes and
//  the hello/welcome/goodbye messages. Kind, call, scope and resource payloads
//  are the existing KTPP models, reused as they are.
//
//  There are no sessions: whoever connects to the socket is trusted, and a
//  plugin is known by the name in its `Hello`. The plugin's `Connect` stream
//  is simply its connection — KeepTalking sends its calls down it (gRPC calls
//  only flow from the side that connected), and the stream ending means the
//  plugin is gone.
//

import Foundation
import MCP

public enum KTPPWire {
    /// `Hello.protocolVersion` / `Welcome.protocolVersion` for this protocol.
    public static let protocolVersion = 0
}

// MARK: - Hello, welcome, goodbye

extension KTPPWire {
    public enum Role: String, Codable, Sendable {
        case plugin
        /// The unified KT Companion app.
        case companion
    }

    /// Plugin → host, the first message on every connection.
    public struct Hello: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        /// Stable plugin name ("computeruse"): the host's catalog identity. A
        /// newer connection with the same name replaces an older one.
        public var name: String
        public var vendor: String
        public var version: String
        public var role: Role
        /// Random per process launch, so a restart is visible even across a
        /// reconnect fast enough to look continuous.
        public var instance: String
        public var features: [String]

        public init(
            protocolVersion: Int = KTPPWire.protocolVersion,
            name: String,
            vendor: String,
            version: String,
            role: Role,
            instance: String,
            features: [String] = []
        ) {
            self.protocolVersion = protocolVersion
            self.name = name
            self.vendor = vendor
            self.version = version
            self.role = role
            self.instance = instance
            self.features = features
        }
    }

    /// Host → plugin, the first message from the host, answering `Hello`.
    public struct Welcome: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var hostNodeID: String
        /// Random per host launch, so a plugin can tell a host restart from a
        /// reconnect.
        public var instance: String

        public init(
            protocolVersion: Int = KTPPWire.protocolVersion,
            hostNodeID: String,
            instance: String
        ) {
            self.protocolVersion = protocolVersion
            self.hostNodeID = hostNodeID
            self.instance = instance
        }
    }

    /// Sent before a side ends the connection on purpose, so the other side
    /// can tell a deliberate end from a lost connection.
    public struct Goodbye: Codable, Sendable, Equatable {
        public enum Reason: String, Codable, Sendable {
            /// The sender is quitting; reconnect when it is back.
            case shuttingDown
            /// A newer connection with the same plugin name replaced this one.
            /// The receiver must not reconnect.
            case superseded
            /// The sender is restarting and expects to return shortly.
            case restarting
            /// A reason this build does not know (a newer peer).
            case unknown

            public init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Reason(rawValue: raw) ?? .unknown
            }
        }

        public var reason: Reason
        public var message: String?

        public init(reason: Reason, message: String? = nil) {
            self.reason = reason
            self.message = message
        }
    }

    /// Answers a request on `Connect` that could not be served.
    public struct Failure: Codable, Sendable, Equatable {
        public enum Code: String, Codable, Sendable {
            /// The receiver does not handle this request.
            case unsupported
            case invalidArgument
            /// The receiver understood the request and declined it.
            case refused
            case cancelled
            case `internal`
            /// A code this build does not know (a newer peer).
            case unknown

            public init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Code(rawValue: raw) ?? .unknown
            }
        }

        public var code: Code
        public var message: String

        public init(code: Code, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Host → plugin: stop servicing an in-flight call.
    public struct CallCancel: Codable, Sendable, Equatable {
        public var requestID: String

        public init(requestID: String) {
            self.requestID = requestID
        }
    }

    /// Host → companion: surface the Companion's main window.
    public struct RevealRequest: Codable, Sendable, Equatable {
        public init() {}
    }

    public struct RevealResult: Codable, Sendable, Equatable {
        /// False when the runtime has no UI attached (a headless run).
        public var revealed: Bool

        public init(revealed: Bool) {
            self.revealed = revealed
        }
    }

    /// The empty answer, for RPCs that only acknowledge.
    public struct Empty: Codable, Sendable, Equatable {
        public init() {}
    }
}

// MARK: - Connect envelopes

extension KTPPWire {
    /// Plugin → host on `Connect`. `id` is set when the message is a request
    /// the host must answer; `replyTo` names the host request it answers.
    /// Encoded flat, with exactly one body key: `{"replyTo": 3, "callResult": {…}}`.
    public struct PluginMessage: Sendable {
        public enum Body: Sendable {
            case hello(Hello)
            /// Sent right after `hello`, and again whenever the kinds change.
            case kinds(KTPPKindsResult)
            case callResult(KTPPCallResult)
            /// Ordered: one sent before a call's result is recorded first.
            case elucidation(KTPPActElucidation)
            case scopeOptions(KTPPScopeOptionsResult)
            case resourceRead(KTPPResourceReadResult)
            case reveal(RevealResult)
            case failure(Failure)
            case goodbye(Goodbye)
            /// A body this build does not know (a newer peer). Never sent.
            case unknown
        }

        public var id: UInt64?
        public var replyTo: UInt64?
        public var body: Body

        public init(id: UInt64? = nil, replyTo: UInt64? = nil, body: Body) {
            self.id = id
            self.replyTo = replyTo
            self.body = body
        }
    }

    /// Host → plugin on `Connect`.
    public struct HostMessage: Sendable {
        public enum Body: Sendable {
            case welcome(Welcome)
            case call(KTPPCallRequest)
            case cancel(CallCancel)
            case scopeOptions(KTPPScopeOptionsRequest)
            case resourceRead(KTPPResourceReadRequest)
            /// Companion connections only.
            case reveal(RevealRequest)
            case failure(Failure)
            case goodbye(Goodbye)
            /// A body this build does not know (a newer peer). Never sent.
            case unknown
        }

        public var id: UInt64?
        public var replyTo: UInt64?
        public var body: Body

        public init(id: UInt64? = nil, replyTo: UInt64? = nil, body: Body) {
            self.id = id
            self.replyTo = replyTo
            self.body = body
        }
    }
}

extension KTPPWire.PluginMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, replyTo
        case hello, kinds, callResult, elucidation, scopeOptions, resourceRead
        case reveal, failure, goodbye
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UInt64.self, forKey: .id)
        replyTo = try container.decodeIfPresent(UInt64.self, forKey: .replyTo)
        var body = Body.unknown
        func take<T: Decodable>(_ key: CodingKeys, _ wrap: (T) -> Body) throws {
            guard case .unknown = body, let value = try container.decodeIfPresent(T.self, forKey: key)
            else { return }
            body = wrap(value)
        }
        try take(.hello, Body.hello)
        try take(.kinds, Body.kinds)
        try take(.callResult, Body.callResult)
        try take(.elucidation, Body.elucidation)
        try take(.scopeOptions, Body.scopeOptions)
        try take(.resourceRead, Body.resourceRead)
        try take(.reveal, Body.reveal)
        try take(.failure, Body.failure)
        try take(.goodbye, Body.goodbye)
        self.body = body
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        switch body {
            case .hello(let value): try container.encode(value, forKey: .hello)
            case .kinds(let value): try container.encode(value, forKey: .kinds)
            case .callResult(let value): try container.encode(value, forKey: .callResult)
            case .elucidation(let value): try container.encode(value, forKey: .elucidation)
            case .scopeOptions(let value): try container.encode(value, forKey: .scopeOptions)
            case .resourceRead(let value): try container.encode(value, forKey: .resourceRead)
            case .reveal(let value): try container.encode(value, forKey: .reveal)
            case .failure(let value): try container.encode(value, forKey: .failure)
            case .goodbye(let value): try container.encode(value, forKey: .goodbye)
            case .unknown:
                throw EncodingError.invalidValue(
                    body,
                    .init(codingPath: encoder.codingPath, debugDescription: "unknown bodies are never sent"))
        }
    }
}

extension KTPPWire.HostMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, replyTo
        case welcome, call, cancel, scopeOptions, resourceRead, reveal, failure, goodbye
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UInt64.self, forKey: .id)
        replyTo = try container.decodeIfPresent(UInt64.self, forKey: .replyTo)
        var body = Body.unknown
        func take<T: Decodable>(_ key: CodingKeys, _ wrap: (T) -> Body) throws {
            guard case .unknown = body, let value = try container.decodeIfPresent(T.self, forKey: key)
            else { return }
            body = wrap(value)
        }
        try take(.welcome, Body.welcome)
        try take(.call, Body.call)
        try take(.cancel, Body.cancel)
        try take(.scopeOptions, Body.scopeOptions)
        try take(.resourceRead, Body.resourceRead)
        try take(.reveal, Body.reveal)
        try take(.failure, Body.failure)
        try take(.goodbye, Body.goodbye)
        self.body = body
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        switch body {
            case .welcome(let value): try container.encode(value, forKey: .welcome)
            case .call(let value): try container.encode(value, forKey: .call)
            case .cancel(let value): try container.encode(value, forKey: .cancel)
            case .scopeOptions(let value): try container.encode(value, forKey: .scopeOptions)
            case .resourceRead(let value): try container.encode(value, forKey: .resourceRead)
            case .reveal(let value): try container.encode(value, forKey: .reveal)
            case .failure(let value): try container.encode(value, forKey: .failure)
            case .goodbye(let value): try container.encode(value, forKey: .goodbye)
            case .unknown:
                throw EncodingError.invalidValue(
                    body,
                    .init(codingPath: encoder.codingPath, debugDescription: "unknown bodies are never sent"))
        }
    }
}
