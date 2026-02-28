import Foundation

enum SignalError: LocalizedError {
    case notConnected
    case invalidResponse
    case remoteError(String)
    case closed

    var errorDescription: String? {
        switch self {
            case .notConnected:
                return "Signaling socket is not connected."
            case .invalidResponse:
                return "Signaling response was invalid."
            case .remoteError(let reason):
                return "Signaling error: \(reason)"
            case .closed:
                return "Signaling socket closed."
        }
    }
}

final class IonJsonRpcSignal: NSObject, @unchecked Sendable {
    private final class PingResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isResumed = false

        func claimResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isResumed {
                return false
            }
            isResumed = true
            return true
        }
    }

    private static let keepAliveIntervalNanoseconds: UInt64 = 20_000_000_000
    private static let reconnectBaseDelayNanoseconds: UInt64 = 500_000_000
    private static let maxReconnectAttempts = 3

    private let url: URL
    private let stateQueue = DispatchQueue(label: "KeepTalking.signal.state")
    private var openWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending = [String: (Result<Data, Error>) -> Void]()
    private var isOpen = false
    private var isConnecting = false
    private var isClosing = false

    var onOffer: ((SessionDescriptionPayload) -> Void)?
    var onTrickle: ((TricklePayload) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private var socketTask: URLSessionWebSocketTask?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        super.init()
    }

    private func debug(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        onLog?("[\(ts)] [signal] \(message)")
    }

    private func preview(_ data: Data, limit: Int = 160) -> String {
        guard let raw = String(data: data, encoding: .utf8) else {
            return "<\(data.count) bytes non-utf8>"
        }
        if raw.count <= limit {
            return raw
        }
        return String(raw.prefix(limit)) + "...(truncated)"
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            var taskToStart: URLSessionWebSocketTask?
            var resumeImmediately = false
            var waitForExistingConnect = false

            self.stateQueue.sync {
                if self.isOpen {
                    resumeImmediately = true
                    return
                }

                self.isClosing = false
                self.openWaiters.append(continuation)

                if self.isConnecting {
                    waitForExistingConnect = true
                    return
                }

                self.isConnecting = true
                self.socketTask?.cancel(with: .goingAway, reason: nil)
                let nextTask = self.session.webSocketTask(with: self.url)
                self.socketTask = nextTask
                taskToStart = nextTask
            }

            if resumeImmediately {
                continuation.resume()
                return
            }

            if waitForExistingConnect {
                self.debug("connect called while opening; waiting existing socket")
                return
            }

            guard let taskToStart else {
                continuation.resume(throwing: SignalError.notConnected)
                return
            }
            self.debug("opening websocket \(self.url.absoluteString)")
            taskToStart.resume()
            self.receiveNextMessage(on: taskToStart)
        }
    }

    func close() {
        stateQueue.sync {
            isClosing = true
            isConnecting = false
            keepAliveTask?.cancel()
            keepAliveTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        debug("closing websocket")
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        failAllPending(with: SignalError.closed)
    }

    func join(
        session sid: String,
        uid: String,
        offer: SessionDescriptionPayload
    ) async throws -> SessionDescriptionPayload {
        let params = JoinParams(sid: sid, uid: uid, offer: offer)
        return try await call(
            method: "join",
            params: params,
            responseType: SessionDescriptionPayload.self
        )
    }

    func offer(
        _ offer: SessionDescriptionPayload
    ) async throws -> SessionDescriptionPayload {
        let params = OfferParams(desc: offer)
        return try await call(
            method: "offer",
            params: params,
            responseType: SessionDescriptionPayload.self
        )
    }

    func answer(_ answer: SessionDescriptionPayload) {
        let params = AnswerParams(desc: answer)
        notify(method: "answer", params: params)
    }

    func trickle(_ trickle: TricklePayload) {
        notify(method: "trickle", params: trickle)
    }

    private func call<Params: Encodable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType _: Response.Type
    ) async throws -> Response {
        var attempt = 0
        while true {
            do {
                return try await callOnce(
                    method: method,
                    params: params,
                    responseType: Response.self
                )
            } catch {
                guard
                    attempt == 0,
                    shouldRetryAfterDisconnect(error),
                    !stateQueue.sync(execute: { isClosing })
                else {
                    throw error
                }

                attempt += 1
                debug(
                    "rpc retry method=\(method) attempt=\(attempt + 1) error=\(error.localizedDescription)"
                )
                try await reconnectWithBackoff(reason: "rpc-\(method)")
            }
        }
    }

    private func callOnce<Params: Encodable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType _: Response.Type
    ) async throws -> Response {
        guard let socketTask else {
            throw SignalError.notConnected
        }

        let id = UUID().uuidString.lowercased()
        let request = RpcRequest(method: method, params: params, id: id)
        let encoded = try JSONEncoder().encode(request)
        debug("send request method=\(method) id=\(id) bytes=\(encoded.count)")

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Response, Error>) in
            stateQueue.sync {
                pending[id] = { result in
                    switch result {
                        case .failure(let error):
                            self.debug(
                                "response failed method=\(method) id=\(id) error=\(error.localizedDescription)"
                            )
                            continuation.resume(throwing: error)
                        case .success(let data):
                            do {
                                let response = try JSONDecoder().decode(
                                    Response.self,
                                    from: data
                                )
                                self.debug(
                                    "response ok method=\(method) id=\(id) bytes=\(data.count)"
                                )
                                continuation.resume(returning: response)
                            } catch {
                                self.debug(
                                    "response decode failed method=\(method) id=\(id) error=\(error.localizedDescription) payload=\(self.preview(data))"
                                )
                                continuation.resume(throwing: error)
                            }
                    }
                }
            }

            socketTask.send(.data(encoded)) { [weak self] error in
                if let error {
                    self?.debug(
                        "send failed method=\(method) id=\(id) error=\(error.localizedDescription)"
                    )
                    self?.resolvePending(id: id, with: .failure(error))
                }
            }
        }
    }

    private func notify<Params: Encodable>(method: String, params: Params) {
        let request = RpcRequest(method: method, params: params, id: nil)
        guard let encoded = try? JSONEncoder().encode(request) else {
            debug("notify encode failed method=\(method)")
            return
        }
        debug("send notify method=\(method) bytes=\(encoded.count)")
        socketTask?.send(.data(encoded)) { [weak self] error in
            guard let self, let error else {
                return
            }
            self.debug(
                "notify send failed method=\(method) error=\(error.localizedDescription)"
            )
            if self.shouldRetryAfterDisconnect(error) {
                self.scheduleReconnect(reason: "notify-\(method)")
            }
        }
    }

    private func receiveNextMessage(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            let isCurrentSocket = self.stateQueue.sync {
                self.socketTask === task
            }
            guard isCurrentSocket else {
                return
            }

            switch result {
                case .failure(let error):
                    let isIntentionalClose = self.stateQueue.sync { self.isClosing }
                    if isIntentionalClose {
                        return
                    } else {
                        self.debug("receive failed error=\(error.localizedDescription)")
                    }
                    self.failAllPending(with: error)
                    if self.shouldRetryAfterDisconnect(error) {
                        self.scheduleReconnect(reason: "receive-failed")
                    }
                case .success(let message):
                    switch message {
                        case .string(let text):
                            self.debug("recv text bytes=\(text.utf8.count)")
                            self.handleMessageData(Data(text.utf8))
                        case .data(let data):
                            self.debug("recv data bytes=\(data.count)")
                            self.handleMessageData(data)
                        @unknown default:
                            self.debug("recv unknown websocket message")
                            break
                    }

                    self.receiveNextMessage(on: task)
            }
        }
    }

    private func shouldRetryAfterDisconnect(_ error: Error) -> Bool {
        if let signalError = error as? SignalError {
            switch signalError {
                case .notConnected, .closed:
                    return true
                case .invalidResponse, .remoteError:
                    return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == 57
                || nsError.code == 54
                || nsError.code == 53
                || nsError.code == 32
            {
                return true
            }
        }
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorNetworkConnectionLost
                || nsError.code == NSURLErrorNotConnectedToInternet
                || nsError.code == NSURLErrorCannotConnectToHost
            {
                return true
            }
        }

        let lowered = nsError.localizedDescription.lowercased()
        return lowered.contains("socket is not connected")
            || lowered.contains("not connected")
    }

    private func scheduleReconnect(reason: String) {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !isClosing else {
                return false
            }
            guard reconnectTask == nil else {
                return false
            }

            reconnectTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.stateQueue.sync {
                        self.reconnectTask = nil
                    }
                }
                do {
                    try await self.reconnectWithBackoff(reason: reason)
                } catch {
                    self.debug(
                        "reconnect abandoned reason=\(reason) error=\(error.localizedDescription)"
                    )
                }
            }
            return true
        }

        if shouldStart {
            debug("reconnect scheduled reason=\(reason)")
        }
    }

    private func reconnectWithBackoff(reason: String) async throws {
        var attempt = 1
        var lastError: Error = SignalError.notConnected

        while attempt <= Self.maxReconnectAttempts {
            if stateQueue.sync(execute: { isClosing }) {
                throw SignalError.closed
            }

            do {
                debug("reconnect attempt=\(attempt) reason=\(reason)")
                try await connect()
                startKeepAliveIfNeeded()
                debug("reconnect succeeded attempt=\(attempt)")
                return
            } catch {
                lastError = error
                debug(
                    "reconnect failed attempt=\(attempt) error=\(error.localizedDescription)"
                )
                guard attempt < Self.maxReconnectAttempts else {
                    break
                }
                let delay =
                    Self.reconnectBaseDelayNanoseconds * UInt64(1 << (attempt - 1))
                try? await Task.sleep(nanoseconds: delay)
                attempt += 1
            }
        }

        throw lastError
    }

    private func startKeepAliveIfNeeded() {
        let shouldStart = stateQueue.sync { () -> Bool in
            if keepAliveTask != nil {
                return false
            }

            keepAliveTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.stateQueue.sync {
                        self.keepAliveTask = nil
                    }
                }

                while !Task.isCancelled {
                    try? await Task.sleep(
                        nanoseconds: Self.keepAliveIntervalNanoseconds
                    )
                    if Task.isCancelled {
                        return
                    }

                    let canPing = self.stateQueue.sync {
                        self.isOpen && !self.isClosing && self.socketTask != nil
                    }
                    guard canPing else {
                        continue
                    }

                    do {
                        try await self.sendPing()
                    } catch {
                        self.debug(
                            "keepalive ping failed error=\(error.localizedDescription)"
                        )
                        if self.shouldRetryAfterDisconnect(error) {
                            self.scheduleReconnect(reason: "keepalive-ping")
                        }
                    }
                }
            }
            return true
        }

        if shouldStart {
            debug(
                "keepalive started interval=\(Self.keepAliveIntervalNanoseconds / 1_000_000_000)s"
            )
        }
    }

    private func sendPing() async throws {
        guard let task = stateQueue.sync(execute: { socketTask }) else {
            throw SignalError.notConnected
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = PingResumeGate()

            task.sendPing { error in
                guard gate.claimResume() else {
                    self.debug("ping callback invoked more than once; ignoring duplicate")
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func handleMessageData(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any]
        else {
            debug("json parse failed payload=\(preview(data))")
            return
        }

        if let method = envelope["method"] as? String {
            debug("recv notify/call method=\(method)")
            guard let params = envelope["params"] else {
                debug("method \(method) missing params")
                return
            }

            guard let paramsData = try? JSONSerialization.data(withJSONObject: params) else {
                debug("method \(method) params json encode failed")
                return
            }

            if method == "offer",
                let offer = try? JSONDecoder().decode(
                    SessionDescriptionPayload.self,
                    from: paramsData
                )
            {
                debug(
                    "offer notify type=\(offer.type) sdpBytes=\(offer.sdp.utf8.count)"
                )
                onOffer?(offer)
                return
            }

            if method == "trickle",
                let trickle = try? JSONDecoder().decode(
                    TricklePayload.self,
                    from: paramsData
                )
            {
                debug(
                    "trickle notify target=\(trickle.target) candidateBytes=\(trickle.candidate.candidate.utf8.count)"
                )
                onTrickle?(trickle)
                return
            }

            debug("unhandled method=\(method) params=\(preview(paramsData))")
            return
        }

        guard let id = envelope["id"] as? String else {
            debug("response without id payload=\(preview(data))")
            return
        }

        if let errorObject = envelope["error"] {
            let text: String
            if let asString = errorObject as? String {
                text = asString
            } else if let encoded = try? JSONSerialization.data(
                withJSONObject: errorObject
            ),
                let rendered = String(data: encoded, encoding: .utf8)
            {
                text = rendered
            } else {
                text = "unknown"
            }

            debug("response error id=\(id) message=\(text)")
            resolvePending(id: id, with: .failure(SignalError.remoteError(text)))
            return
        }

        guard let resultObject = envelope["result"],
            let resultData = try? JSONSerialization.data(
                withJSONObject: resultObject
            )
        else {
            debug("response invalid id=\(id) payload=\(preview(data))")
            resolvePending(id: id, with: .failure(SignalError.invalidResponse))
            return
        }

        resolvePending(id: id, with: .success(resultData))
    }

    private func resolvePending(id: String, with result: Result<Data, Error>) {
        let handler: ((Result<Data, Error>) -> Void)? = stateQueue.sync {
            pending.removeValue(forKey: id)
        }

        if handler == nil {
            debug("resolve pending id=\(id) with no waiter")
        }
        handler?(result)
    }

    private func failAllPending(with error: Error) {
        let allAndState: (callbacks: [(Result<Data, Error>) -> Void], shouldLog: Bool) =
            stateQueue.sync {
                let callbacks = Array(pending.values)
                pending.removeAll()

                let waiters = openWaiters
                openWaiters.removeAll(keepingCapacity: true)
                isOpen = false
                isConnecting = false
                for waiter in waiters {
                    waiter.resume(throwing: error)
                }

                return (callbacks, !isClosing)
            }

        if allAndState.shouldLog {
            debug(
                "fail all pending count=\(allAndState.callbacks.count) error=\(error.localizedDescription)"
            )
        }
        for callback in allAndState.callbacks {
            callback(.failure(error))
        }
    }
}

extension IonJsonRpcSignal: URLSessionWebSocketDelegate {
    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let isCurrentSocket = stateQueue.sync {
            socketTask === webSocketTask
        }
        guard isCurrentSocket else {
            debug("ignoring didOpen from stale websocket task")
            return
        }

        debug("websocket opened")
        stateQueue.sync {
            isOpen = true
            isConnecting = false
            isClosing = false
            let waiters = openWaiters
            openWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }
        startKeepAliveIfNeeded()
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason closeReason: Data?
    ) {
        let shouldHandle = stateQueue.sync {
            socketTask === webSocketTask
        }
        guard shouldHandle else {
            debug("ignoring didClose from stale websocket task")
            return
        }

        let shouldLog = stateQueue.sync { !isClosing }
        if shouldLog {
            if let closeReason {
                debug(
                    "websocket closed code=\(closeCode.rawValue) reason=\(preview(closeReason))"
                )
            } else {
                debug("websocket closed code=\(closeCode.rawValue)")
            }
        }
        failAllPending(with: SignalError.closed)
        if shouldLog {
            scheduleReconnect(reason: "close-\(closeCode.rawValue)")
        }
    }
}
