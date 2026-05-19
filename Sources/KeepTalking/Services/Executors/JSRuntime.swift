import Foundation

/// Runtime that evaluates a JavaScript source string and returns the value of
/// the last expression together with anything written to `console.*`.
///
/// The SDK is platform-neutral, so the actual JS engine (JavaScriptCore on
/// Apple platforms, QuickJS / duktape / etc. elsewhere) is supplied by the
/// host via `KeepTalkingClient.setJSRuntime`. No JS-engine imports leak into
/// the SDK target — Linux server peers stay buildable as long as they ship
/// (or omit) their own runtime conformance.
///
/// V1 is intentionally local-only: no `fetch`, no host bridge to KT data,
/// no action invocation. The protocol shape leaves room for a future
/// host-bridge parameter without breaking call sites.
public protocol KeepTalkingJSRuntime: Sendable {
    func evaluate(
        _ source: String,
        options: KeepTalkingJSEvaluationOptions
    ) async throws -> KeepTalkingJSEvaluationResult
}

public struct KeepTalkingJSEvaluationOptions: Sendable {
    /// Wall-clock budget for a single evaluation. The runtime is expected to
    /// abort the JS context if this is exceeded.
    public var timeoutMilliseconds: Int
    /// Cap on the combined byte length of console output + serialized result.
    /// Implementations should truncate (not error) when the cap is reached.
    public var maxOutputBytes: Int

    public init(
        timeoutMilliseconds: Int = 5_000,
        maxOutputBytes: Int = 16_384
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxOutputBytes = maxOutputBytes
    }
}

public struct KeepTalkingJSEvaluationResult: Sendable {
    /// String form of the value of the last expression. Objects/arrays are
    /// JSON-stringified; primitives are coerced via `String(value)`.
    /// Empty string when the source evaluates to `undefined` or `null`.
    public let value: String
    /// Concatenated `console.log/info/warn/error` output, newline-joined,
    /// in the order produced. Truncated to `maxOutputBytes`.
    public let consoleOutput: String
    /// True iff the JS threw an uncaught exception or the runtime aborted
    /// (timeout, out-of-memory, etc.). `errorMessage` carries detail.
    public let isError: Bool
    public let errorMessage: String?
    /// True iff `consoleOutput` or `value` was truncated to fit the byte cap.
    public let truncated: Bool

    public init(
        value: String,
        consoleOutput: String,
        isError: Bool,
        errorMessage: String? = nil,
        truncated: Bool = false
    ) {
        self.value = value
        self.consoleOutput = consoleOutput
        self.isError = isError
        self.errorMessage = errorMessage
        self.truncated = truncated
    }
}

public enum KeepTalkingJSRuntimeError: LocalizedError {
    case runtimeNotConfigured

    public var errorDescription: String? {
        switch self {
            case .runtimeNotConfigured:
                return "No JavaScript runtime is configured on this client."
        }
    }
}
