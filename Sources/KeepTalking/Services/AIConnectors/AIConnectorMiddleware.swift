import Foundation

/// One `completeTurn` call, as a value a middleware can read or rewrite.
public struct AIConnectorRequest: Sendable {
    public var messages: [AIMessage]
    public var tools: [KeepTalkingActionToolDefinition]
    public var model: String
    public var toolChoice: AIToolChoice?
    public var stage: AIStage
    public var configuration: AITurnConfiguration?
    public var toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
}

/// A slot around a connector's calls for instrumentation that stays out of
/// the product — recording or metering calls, rewriting requests in a
/// validation harness. The SDK installs none. Wrap a connector in
/// `AIMiddlewareConnector` and hand it to `KeepTalkingAgentConfiguration`
/// like any other: each call's `configuration?.telemetry` says which part of
/// the run made it (main loop, consult, freeze…), and its result's `usage`
/// what it cost.
public protocol AIConnectorMiddleware: Sendable {
    func completeTurn(
        _ request: AIConnectorRequest,
        next: @Sendable (AIConnectorRequest) async throws -> AITurnResult
    ) async throws -> AITurnResult
}

/// A connector whose calls pass through a middleware on their way to `inner`.
public actor AIMiddlewareConnector: AIConnector {
    public let inner: any AIConnector
    public let middleware: any AIConnectorMiddleware
    public nonisolated let capabilities: AIConnectorCapabilities

    public init(_ inner: any AIConnector, middleware: any AIConnectorMiddleware) {
        self.inner = inner
        self.middleware = middleware
        self.capabilities = inner.capabilities
    }

    public func completeTurn(
        messages: [AIMessage],
        tools: [KeepTalkingActionToolDefinition],
        model: String,
        toolChoice: AIToolChoice?,
        stage: AIStage,
        configuration: AITurnConfiguration?,
        toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])?
    ) async throws -> AITurnResult {
        let inner = inner
        return try await middleware.completeTurn(
            AIConnectorRequest(
                messages: messages, tools: tools, model: model, toolChoice: toolChoice, stage: stage,
                configuration: configuration, toolExecutor: toolExecutor
            )
        ) { request in
            try await inner.completeTurn(
                messages: request.messages,
                tools: request.tools,
                model: request.model,
                toolChoice: request.toolChoice,
                stage: request.stage,
                configuration: request.configuration,
                toolExecutor: request.toolExecutor
            )
        }
    }
}
