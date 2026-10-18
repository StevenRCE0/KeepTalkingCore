#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
import Logging
import MCP

/// Streamable HTTP for Linux, where swift-sdk's `HTTPClientTransport` cannot
/// stream.
///
/// corelibs Foundation has no `URLSession.bytes(for:)`, so on Linux the SDK
/// transport reads every POST response with `data(for:)`, which returns only
/// once the body ends. A server that answers with `text/event-stream` and keeps
/// the stream open — Sonos does, once the request carries a valid token — is
/// never read at all: the handshake waits out its whole timeout. And the SDK
/// hands such a body to the client unparsed, so even a stream that does end is
/// not understood (it logs "SSE responses aren't fully supported on Linux").
///
/// This transport keeps the SDK's contract and its OAuth behaviour — the same
/// headers, the same 401/403 → `HTTPClientAuthorizer.handleChallenge` → retry
/// loop — but reads the response through a data delegate, so an event stream
/// is parsed as it arrives and each message reaches the client at once. The
/// stream is released as soon as it has carried the reply to the request that
/// opened it.
///
/// Its two `URLSession`s are process-wide and never invalidated: invalidating
/// a corelibs session that completed a request and then freeing it aborts the
/// process (swift-corelibs-foundation #4791).
actor LinuxStreamingHTTPTransport: Transport {
    nonisolated let logger: Logger

    private let endpoint: URL
    private let authorizer: (any HTTPClientAuthorizer)?
    private let requestModifier: @Sendable (URLRequest) -> URLRequest

    private var isConnected = false
    private var sessionID: String?
    private var protocolVersion: String?
    private var streams: [Int: Task<Void, Never>] = [:]
    private var nextStreamID = 0

    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(
        endpoint: URL,
        authorizer: (any HTTPClientAuthorizer)?,
        requestModifier: @escaping @Sendable (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.authorizer = authorizer
        self.requestModifier = requestModifier
        self.logger = logger ?? Logger(label: "keepTalking.mcp.linuxHTTP") { _ in SwiftLogNoOpLogHandler() }
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.messageStream = stream
        self.messageContinuation = continuation
    }

    func connect() async throws {
        isConnected = true
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        for task in streams.values { task.cancel() }
        streams.removeAll()
        messageContinuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }
        if let authorizer {
            do {
                try authorizer.validateEndpointSecurity(for: endpoint)
            } catch {
                throw MCPError.internalError(
                    "Authorization flow failed: \(error.localizedDescription)")
            }
            try? await authorizer.prepareAuthorization(
                for: endpoint, session: LinuxHTTPSessions.plain)
        }

        let message = Self.jsonObject(data)
        let method = (message?["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationKey = method?.isEmpty == false ? method : nil
        let requestID = message.flatMap { $0["method"] != nil ? $0["id"] : nil }.map(Self.idKey)

        var attempts = 0
        while true {
            // A retry after a sign-in can come long after the caller gave up.
            guard isConnected else {
                throw MCPError.internalError("Transport not connected")
            }
            let opened = try await LinuxHTTPSessions.streamer.open(request(for: data))
            let response = opened.response
            let status = response.statusCode

            if status == 401 || status == 403 {
                opened.cancel()
                guard let authorizer else { throw Self.challengeError(status) }
                let handled: Bool
                do {
                    handled = try await authorizer.handleChallenge(
                        statusCode: status,
                        headers: Self.headers(of: response),
                        endpoint: endpoint,
                        operationKey: operationKey,
                        session: LinuxHTTPSessions.plain
                    )
                } catch {
                    throw MCPError.internalError(
                        "Authorization flow failed: \(error.localizedDescription)")
                }
                attempts += 1
                if handled, attempts < authorizer.maxAuthorizationAttempts { continue }
                throw Self.challengeError(status)
            }

            if let newSessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                sessionID = newSessionID
            }

            guard (200..<300).contains(status) else {
                let body = String(decoding: try await opened.collect(limit: 2048), as: UTF8.self)
                if status == 404, sessionID != nil {
                    sessionID = nil
                    throw MCPError.internalError("Session expired")
                }
                throw MCPError.internalError(
                    "HTTP \(status)\(body.isEmpty ? "" : ": \(body.prefix(300))")")
            }

            // 202 Accepted: a notification or response, nothing comes back.
            if status == 202 {
                opened.cancel()
                return
            }

            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("text/event-stream") {
                track(stream: opened, closingOn: requestID)
            } else if contentType.contains("application/json") {
                let body = try await opened.collect(limit: nil)
                if !body.isEmpty { deliver(body) }
            } else {
                opened.cancel()
                logger.warning("Unexpected content type: \(contentType)")
            }
            return
        }
    }

    // MARK: - Requests

    private func request(for data: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let value = authorizer?.authorizationHeader(for: endpoint) {
            request.setValue(value, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        return requestModifier(request)
    }

    // MARK: - Event streams

    /// Reads an event stream off the request path, so `send` returns as the
    /// SDK's does once the response has started. The stream is dropped when
    /// it has carried the reply to `requestID`, when the server ends it, or on
    /// disconnect.
    private func track(stream opened: LinuxStreamingResponse, closingOn requestID: String?) {
        let id = nextStreamID
        nextStreamID += 1
        streams[id] = Task { [weak self] in
            var parser = ServerSentEventParser()
            do {
                for try await chunk in opened.body {
                    for event in parser.feed(chunk) {
                        let payload = Data(event.utf8)
                        await self?.deliver(payload)
                        if let requestID, Self.isReply(payload, to: requestID) {
                            opened.cancel()
                            await self?.untrack(id)
                            return
                        }
                    }
                }
                for event in parser.finish() {
                    await self?.deliver(Data(event.utf8))
                }
            } catch {
                self?.logger.debug("Event stream ended: \(error)")
            }
            await self?.untrack(id)
        }
    }

    private func untrack(_ id: Int) {
        streams.removeValue(forKey: id)
    }

    private func deliver(_ payload: Data) {
        guard isConnected else { return }
        noteProtocolVersion(in: payload)
        messageContinuation.yield(payload)
    }

    /// The version the server settled on in `initialize`, sent on every later
    /// request as the spec asks. The client never tells this transport — it
    /// only tells `HTTPClientTransport` — so it is read off the reply.
    private func noteProtocolVersion(in payload: Data) {
        guard protocolVersion == nil,
            let result = Self.jsonObject(payload)?["result"] as? [String: Any],
            let version = result["protocolVersion"] as? String,
            result["serverInfo"] != nil
        else { return }
        protocolVersion = version
    }

    // MARK: - Helpers

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func idKey(_ id: Any) -> String {
        if let string = id as? String { return "s:\(string)" }
        if let number = id as? NSNumber { return "n:\(number.int64Value)" }
        return "?:\(id)"
    }

    private static func isReply(_ payload: Data, to requestID: String) -> Bool {
        guard let object = jsonObject(payload), object["method"] == nil, let id = object["id"]
        else { return false }
        return idKey(id) == requestID
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return headers
    }

    private static func challengeError(_ status: Int) -> MCPError {
        status == 403
            ? MCPError.internalError("Access forbidden")
            : MCPError.internalError("Authentication required")
    }
}

/// Splits a `text/event-stream` body into the `data` of each event, joined as
/// the spec says: one event per blank line, its `data:` lines joined with a
/// newline. Comments, `event:`, `id:` and `retry:` are read and dropped — an
/// MCP stream carries JSON-RPC messages in `data` and nothing else we act on.
struct ServerSentEventParser {
    private var buffer = Data()
    private var dataLines: [String] = []

    /// Consumes a chunk and returns the events it completed.
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var events: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if let event = consume(String(decoding: line, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    /// The last event, if the stream ended without its closing blank line.
    mutating func finish() -> [String] {
        if !buffer.isEmpty {
            let rest = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            _ = consume(rest)
        }
        return dispatch().map { [$0] } ?? []
    }

    private mutating func consume(_ line: String) -> String? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        if field == "data" { dataLines.append(String(value)) }
        return nil
    }

    private mutating func dispatch() -> String? {
        defer { dataLines.removeAll() }
        guard !dataLines.isEmpty else { return nil }
        let event = dataLines.joined(separator: "\n")
        return event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : event
    }
}

/// A response whose headers have arrived and whose body is still coming.
final class LinuxStreamingResponse: @unchecked Sendable {
    let response: HTTPURLResponse
    let body: AsyncThrowingStream<Data, Swift.Error>
    private let task: URLSessionDataTask

    init(response: HTTPURLResponse, body: AsyncThrowingStream<Data, Swift.Error>, task: URLSessionDataTask) {
        self.response = response
        self.body = body
        self.task = task
    }

    func cancel() {
        task.cancel()
    }

    /// The whole body, or its first `limit` bytes.
    func collect(limit: Int?) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if let limit, data.count >= limit {
                cancel()
                return data.prefix(limit)
            }
        }
        return data
    }
}

/// The two process-wide sessions: `plain` for the authorizer's discovery,
/// registration and token calls, `streamer` for MCP requests read as they
/// arrive.
enum LinuxHTTPSessions {
    static let plain = URLSession(configuration: .default)
    static let streamer = LinuxStreamingSession()
}

/// A data-delegate session that hands each response over as soon as its
/// headers arrive, with the body as a stream of chunks.
final class LinuxStreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var opened: CheckedContinuation<LinuxStreamingResponse, Swift.Error>?
        let body: AsyncThrowingStream<Data, Swift.Error>
        let bodyContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
        let task: URLSessionDataTask
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let configuration: URLSessionConfiguration
    private let allowsRedirect: (@Sendable (URLRequest) -> Bool)?
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    /// Never invalidate one: corelibs aborts when a session that completed a
    /// request is invalidated and then freed (swift-corelibs-foundation
    /// #4791), so instances live for the process.
    ///
    /// - Parameter allowsRedirect: Called for each redirect; `false` stops
    ///   at the redirect response instead of following it. `nil` follows all.
    init(
        configuration: URLSessionConfiguration? = nil,
        allowsRedirect: (@Sendable (URLRequest) -> Bool)? = nil
    ) {
        self.configuration = configuration ?? {
            let configuration = URLSessionConfiguration.default
            // An event stream may sit idle between messages for longer than
            // the default 60 s; how long to wait is the caller's timeout.
            configuration.timeoutIntervalForRequest = 3600
            return configuration
        }()
        self.allowsRedirect = allowsRedirect
        super.init()
    }

    /// Starts `request` and returns once its response headers are in.
    func open(_ request: URLRequest) async throws -> LinuxStreamingResponse {
        let task = session.dataTask(with: request)
        let (body, bodyContinuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(
                        opened: continuation, body: body,
                        bodyContinuation: bodyContinuation, task: task)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let opened: (CheckedContinuation<LinuxStreamingResponse, Swift.Error>, LinuxStreamingResponse)? =
            lock.withLock {
                guard var entry = pending[dataTask.taskIdentifier],
                    let continuation = entry.opened
                else { return nil }
                entry.opened = nil
                pending[dataTask.taskIdentifier] = entry
                guard let http = response as? HTTPURLResponse else { return nil }
                return (continuation, LinuxStreamingResponse(response: http, body: entry.body, task: entry.task))
            }
        completionHandler(.allow)
        if let (continuation, value) = opened {
            continuation.resume(returning: value)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(allowsRedirect.map { $0(request) } ?? true ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let continuation = lock.withLock { pending[dataTask.taskIdentifier]?.bodyContinuation }
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else {
            return
        }
        if let opened = entry.opened {
            opened.resume(throwing: error ?? MCPError.internalError("Invalid HTTP response"))
        }
        if let error, (error as? URLError)?.code != .cancelled {
            entry.bodyContinuation.finish(throwing: error)
        } else {
            entry.bodyContinuation.finish()
        }
    }
}
#endif
