import Foundation

struct SessionDescriptionPayload: Codable, Sendable {
    let type: String
    let sdp: String
}

struct IceCandidatePayload: Codable, Sendable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32?
    let usernameFragment: String?
}

struct TricklePayload: Codable, Sendable {
    let target: Int
    let candidate: IceCandidatePayload
}

struct JoinParams: Codable, Sendable {
    let sid: String
    let uid: String
    let offer: SessionDescriptionPayload
}

struct OfferParams: Codable, Sendable {
    let desc: SessionDescriptionPayload
}

struct AnswerParams: Codable, Sendable {
    let desc: SessionDescriptionPayload
}

struct RpcRequest<Params: Encodable>: Encodable {
    let method: String
    let params: Params
    let id: String?

    enum CodingKeys: String, CodingKey {
        case method
        case params
        case id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
        try container.encodeIfPresent(id, forKey: .id)
    }
}
