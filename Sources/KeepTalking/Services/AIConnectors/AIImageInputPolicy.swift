import Crypto
import Foundation
import NIOConcurrencyHelpers

// MARK: - AIImageInputPolicy

/// What one provider endpoint accepts as inline image input. These are wire
/// limits, not model traits: Claude through OpenRouter still hits Anthropic's
/// per-image ceiling, so a connector picks the policy from its backend and,
/// for a router, the model's vendor prefix.
///
/// Byte limits are counted on the base64 text that actually travels in the
/// JSON body (4/3 of the binary). `headroom` is held back from every limit so
/// a re-encode that lands a little over its estimate still fits.
public struct AIImageInputPolicy: Sendable, Hashable {
    /// Longest side, in pixels. Larger images are downscaled before sending;
    /// providers resize anything above this server-side anyway.
    public var maxPixelSize: Int
    /// Hard ceiling on one image's base64 payload.
    public var maxEncodedBytesPerImage: Int
    /// Hard ceiling on all images' base64 payload in one request.
    public var maxEncodedBytesPerRequest: Int
    public var maxImagesPerRequest: Int
    /// Fraction of each byte ceiling left unused.
    public var headroom: Double
    /// The downscaler never shrinks an image's longest side below this to make
    /// it fit; an image that still doesn't fit is dropped instead.
    public var minPixelSize: Int
    /// The lowest JPEG quality the downscaler may step down to.
    public var minJPEGQuality: Double
    /// Image types the endpoint decodes. Anything else is transcoded to JPEG.
    public var acceptedMIMETypes: Set<String>

    public init(
        maxPixelSize: Int,
        maxEncodedBytesPerImage: Int,
        maxEncodedBytesPerRequest: Int,
        maxImagesPerRequest: Int,
        headroom: Double = 0.15,
        minPixelSize: Int = 512,
        minJPEGQuality: Double = 0.5,
        acceptedMIMETypes: Set<String> = Self.commonMIMETypes
    ) {
        self.maxPixelSize = maxPixelSize
        self.maxEncodedBytesPerImage = maxEncodedBytesPerImage
        self.maxEncodedBytesPerRequest = maxEncodedBytesPerRequest
        self.maxImagesPerRequest = maxImagesPerRequest
        self.headroom = headroom
        self.minPixelSize = minPixelSize
        self.minJPEGQuality = minJPEGQuality
        self.acceptedMIMETypes = acceptedMIMETypes
    }

    public static let commonMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    /// Anthropic Messages: 5 MB of base64 per image, 100 images and a 32 MB
    /// body per request, and a recommended longest side of 1568 px.
    public static let anthropic = AIImageInputPolicy(
        maxPixelSize: 1568,
        maxEncodedBytesPerImage: 5 * 1024 * 1024,
        maxEncodedBytesPerRequest: 24 * 1024 * 1024,
        maxImagesPerRequest: 100
    )

    /// OpenAI Chat Completions: 50 MB of image payload per request; high
    /// detail fits the image into 2048 × 2048 before tiling.
    public static let openAI = AIImageInputPolicy(
        maxPixelSize: 2048,
        maxEncodedBytesPerImage: 20 * 1024 * 1024,
        maxEncodedBytesPerRequest: 40 * 1024 * 1024,
        maxImagesPerRequest: 500
    )

    /// An endpoint whose limits are unknown (custom bases, other routed
    /// vendors). Small enough for every provider KT has met.
    public static let conservative = AIImageInputPolicy(
        maxPixelSize: 1568,
        maxEncodedBytesPerImage: 4 * 1024 * 1024,
        maxEncodedBytesPerRequest: 16 * 1024 * 1024,
        maxImagesPerRequest: 20
    )

    /// The policy for a model reached through a router (OpenRouter), keyed on
    /// the vendor prefix of its slug (`anthropic/claude-…`).
    public static func routed(model: String) -> AIImageInputPolicy {
        let vendor = model.split(separator: "/", maxSplits: 1).first?.lowercased() ?? ""
        switch vendor {
            case "anthropic": return .anthropic
            case "openai": return .openAI
            default: return .conservative
        }
    }

    /// Per-image base64 budget after headroom.
    public var targetEncodedBytesPerImage: Int {
        Int(Double(maxEncodedBytesPerImage) * (1 - headroom))
    }

    /// Per-request base64 budget after headroom.
    public var targetEncodedBytesPerRequest: Int {
        Int(Double(maxEncodedBytesPerRequest) * (1 - headroom))
    }

    /// What the downscaler aims for: binary bytes whose base64 (plus the data
    /// URL prefix) stays inside the per-image budget.
    var encodingTarget: KeepTalkingImageEncodingTarget {
        KeepTalkingImageEncodingTarget(
            maxPixelSize: maxPixelSize,
            maxBytes: max(0, targetEncodedBytesPerImage - 64) / 4 * 3,
            minPixelSize: minPixelSize,
            minJPEGQuality: minJPEGQuality,
            acceptedMIMETypes: acceptedMIMETypes
        )
    }
}

// MARK: - AIImageInputFitter

/// Fits the image parts of a request to an `AIImageInputPolicy` right before a
/// connector translates it — the one place every image passes, whichever path
/// produced it (a prompt attachment, a read resource, an MCP result, a plugin
/// resource) and whichever loop is sending (main, ACT, planners).
///
/// Each image is re-encoded to the per-image budget once and remembered, so an
/// agent loop resending the same history does not re-encode it every turn.
/// Then the request budget is spent newest first: the images the model is
/// looking at now survive, older ones become a note.
final class AIImageInputFitter: Sendable {
    static let oversizedImageNote =
        "[An image was attached here, but it could not be made small enough for this provider.]"
    static let overBudgetImageNote =
        "[An earlier image was left out to keep this request within the provider's size limit.]"

    private struct Cache {
        var fitted: [SHA256Digest: URL?] = [:]
        var order: [SHA256Digest] = []
    }

    private static let cacheLimit = 64
    private let cache = NIOLockedValueBox(Cache())

    func fitted(_ messages: [AIMessage], policy: AIImageInputPolicy) -> [AIMessage] {
        guard messages.contains(where: \.hasImageParts) else { return messages }

        var remainingBytes = policy.targetEncodedBytesPerRequest
        var remainingImages = policy.maxImagesPerRequest
        var result = messages
        for messageIndex in result.indices.reversed() {
            guard case .parts(var parts) = result[messageIndex].content,
                result[messageIndex].hasImageParts
            else { continue }
            for partIndex in parts.indices.reversed() {
                guard case .imageURL(let url) = parts[partIndex] else { continue }
                guard let fittedURL = fittedImage(url, policy: policy) else {
                    parts[partIndex] = .text(Self.oversizedImageNote)
                    continue
                }
                let cost = Self.encodedCost(of: fittedURL)
                guard remainingImages > 0, cost <= remainingBytes else {
                    parts[partIndex] = .text(Self.overBudgetImageNote)
                    continue
                }
                remainingImages -= 1
                remainingBytes -= cost
                parts[partIndex] = .imageURL(fittedURL)
            }
            result[messageIndex] = result[messageIndex].replacingContent(.parts(parts))
        }
        return result
    }

    /// The image re-encoded to `policy`, or nil when it cannot be brought
    /// under the per-image budget. Remote URLs pass through: the provider
    /// fetches them, and they cost nothing in the request body.
    private func fittedImage(_ url: URL, policy: AIImageInputPolicy) -> URL? {
        let raw = url.absoluteString
        guard let dataURL = DataURL(raw) else { return url }

        var hasher = SHA256()
        hasher.update(data: Data("\(policy.hashValue)|".utf8))
        hasher.update(data: Data(raw.utf8))
        let key = hasher.finalize()
        if let cached = cache.withLockedValue({ $0.fitted[key] }) { return cached }

        let fitted = Self.fit(dataURL, original: url, policy: policy)
        cache.withLockedValue { cache in
            if cache.fitted.updateValue(fitted, forKey: key) == nil {
                cache.order.append(key)
            }
            if cache.order.count > Self.cacheLimit {
                cache.fitted.removeValue(forKey: cache.order.removeFirst())
            }
        }
        return fitted
    }

    private static func fit(
        _ dataURL: DataURL, original: URL, policy: AIImageInputPolicy
    ) -> URL? {
        let target = policy.encodingTarget
        guard
            let data = Data(
                base64Encoded: String(dataURL.base64), options: .ignoreUnknownCharacters)
        else {
            // Not decodable here; send it as is when it fits, so a payload the
            // provider can read is never thrown away on our account.
            return dataURL.base64.utf8.count <= policy.targetEncodedBytesPerImage ? original : nil
        }
        if data.count <= target.maxBytes ?? .max,
            policy.acceptedMIMETypes.contains(dataURL.mimeType.lowercased()),
            KeepTalkingImageDownscaler.pixelSize(of: data).map({
                max($0.width, $0.height) <= policy.maxPixelSize
            }) ?? true
        {
            return original
        }
        guard
            let scaled = KeepTalkingImageDownscaler.fitted(
                data, mimeType: dataURL.mimeType, target: target)
        else { return nil }
        return URL(string: "data:\(scaled.mimeType);base64,\(scaled.data.base64EncodedString())")
    }

    private static func encodedCost(of url: URL) -> Int {
        url.absoluteString.hasPrefix("data:") ? url.absoluteString.utf8.count : 0
    }
}

/// The two halves of a `data:<mime>;base64,<payload>` URL.
private struct DataURL {
    let mimeType: String
    let base64: Substring

    init?(_ raw: String) {
        guard raw.hasPrefix("data:"),
            let comma = raw.firstIndex(of: ","),
            let marker = raw.range(of: ";base64", range: raw.startIndex..<comma)
        else { return nil }
        mimeType = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<marker.lowerBound])
        base64 = raw[raw.index(after: comma)...]
    }
}

extension AIMessage {
    var hasImageParts: Bool {
        guard case .parts(let parts) = content else { return false }
        return parts.contains { if case .imageURL = $0 { return true } else { return false } }
    }

    func replacingContent(_ content: Content) -> AIMessage {
        AIMessage(
            role: role,
            content: content,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            name: name,
            audioReference: audioReference
        )
    }
}
