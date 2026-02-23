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
        case let .remoteError(reason):
            return "Signaling error: \(reason)"
        case .closed:
            return "Signaling socket closed."
        }
    }
}

final class IonJsonRpcSignal: NSObject, @unchecked Sendable {
    private let url: URL
    private let stateQueue = DispatchQueue(label: "KeepTalking.signal.state")
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var pending = [String: (Result<Data, Error>) -> Void]()
    private var isOpen = false

    var onOffer: ((SessionDescriptionPayload) -> Void)?
    var onTrickle: ((TricklePayload) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private var socketTask: URLSessionWebSocketTask?

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
        if isOpen {
            debug("connect called while already open")
            return
        }

        debug("opening websocket \(url.absoluteString)")
        socketTask = session.webSocketTask(with: url)
        socketTask?.resume()
        receiveNextMessage()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.sync {
                self.openWaiter = continuation
            }
        }
    }

    func close() {
        debug("closing websocket")
        socketTask?.cancel(with: .normalClosure, reason: nil)
        failAllPending(with: SignalError.closed)
    }

    func join(session sid: String, uid: String, offer: SessionDescriptionPayload) async throws -> SessionDescriptionPayload {
        let params = JoinParams(sid: sid, uid: uid, offer: offer)
        return try await call(method: "join", params: params, responseType: SessionDescriptionPayload.self)
    }

    func offer(_ offer: SessionDescriptionPayload) async throws -> SessionDescriptionPayload {
        let params = OfferParams(desc: offer)
        return try await call(method: "offer", params: params, responseType: SessionDescriptionPayload.self)
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
        guard socketTask != nil else {
            throw SignalError.notConnected
        }

        let id = UUID().uuidString.lowercased()
        let request = RpcRequest(method: method, params: params, id: id)
        let encoded = try JSONEncoder().encode(request)
        debug("send request method=\(method) id=\(id) bytes=\(encoded.count)")

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
            stateQueue.sync {
                pending[id] = { result in
                    switch result {
                    case let .failure(error):
                        self.debug("response failed method=\(method) id=\(id) error=\(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    case let .success(data):
                        do {
                            let response = try JSONDecoder().decode(Response.self, from: data)
                            self.debug("response ok method=\(method) id=\(id) bytes=\(data.count)")
                            continuation.resume(returning: response)
                        } catch {
                            self.debug("response decode failed method=\(method) id=\(id) error=\(error.localizedDescription) payload=\(self.preview(data))")
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            socketTask?.send(.data(encoded)) { [weak self] error in
                if let error {
                    self?.debug("send failed method=\(method) id=\(id) error=\(error.localizedDescription)")
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
        socketTask?.send(.data(encoded)) { _ in }
    }

    private func receiveNextMessage() {
        socketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case let .failure(error):
                self.debug("receive failed error=\(error.localizedDescription)")
                self.failAllPending(with: error)
            case let .success(message):
                switch message {
                case let .string(text):
                    self.debug("recv text bytes=\(text.utf8.count)")
                    self.handleMessageData(Data(text.utf8))
                case let .data(data):
                    self.debug("recv data bytes=\(data.count)")
                    self.handleMessageData(data)
                @unknown default:
                    self.debug("recv unknown websocket message")
                    break
                }

                self.receiveNextMessage()
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
               let offer = try? JSONDecoder().decode(SessionDescriptionPayload.self, from: paramsData)
            {
                debug("offer notify type=\(offer.type) sdpBytes=\(offer.sdp.utf8.count)")
                onOffer?(offer)
                return
            }

            if method == "trickle",
               let trickle = try? JSONDecoder().decode(TricklePayload.self, from: paramsData)
            {
                debug("trickle notify target=\(trickle.target) candidateBytes=\(trickle.candidate.candidate.utf8.count)")
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
            } else if let encoded = try? JSONSerialization.data(withJSONObject: errorObject),
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
              let resultData = try? JSONSerialization.data(withJSONObject: resultObject)
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
        let all: [(Result<Data, Error>) -> Void] = stateQueue.sync {
            let callbacks = Array(pending.values)
            pending.removeAll()

            let waiter = openWaiter
            openWaiter = nil
            isOpen = false
            waiter?.resume(throwing: error)

            return callbacks
        }

        debug("fail all pending count=\(all.count) error=\(error.localizedDescription)")
        for callback in all {
            callback(.failure(error))
        }
    }
}

extension IonJsonRpcSignal: URLSessionWebSocketDelegate {
    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        debug("websocket opened")
        stateQueue.sync {
            isOpen = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason closeReason: Data?
    ) {
        if let closeReason {
            debug("websocket closed code=\(closeCode.rawValue) reason=\(preview(closeReason))")
        } else {
            debug("websocket closed code=\(closeCode.rawValue)")
        }
        failAllPending(with: SignalError.closed)
    }
}
