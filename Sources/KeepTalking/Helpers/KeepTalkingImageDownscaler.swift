import Foundation

/// Resizes and re-encodes an image before it is handed to a model. LLM vision
/// endpoints reject images over their byte limits and down-sample (and bill
/// by) resolution, so an image is brought within a pixel cap and, when asked,
/// a byte budget, preserving aspect ratio.
///
/// The concrete implementation relies on Apple imaging frameworks
/// (CoreGraphics/ImageIO), which aren't available on every platform the SDK
/// targets (e.g. the headless Linux/Windows daemon). The SDK therefore only
/// owns the *seam*: a host registers a downscaler via
/// `KeepTalkingImageDownscaler.register(_:)`, and image handling falls back to a
/// pass-through when none is registered. Apple hosts (the app) inject a
/// CoreGraphics/ImageIO backed implementation at launch.
public protocol KeepTalkingImageDownscaling: Sendable {
    /// Re-encodes `data` toward `target`: longest side within
    /// `target.maxPixelSize`, and — when `target.maxBytes` is set — encoded
    /// size within it, stepping JPEG quality down to `minJPEGQuality` and then
    /// the longest side down to `minPixelSize` until it fits. A type outside
    /// `acceptedMIMETypes` is transcoded. Returns the input unchanged when it
    /// already meets the target.
    ///
    /// Implementations MUST fail open — returning their best attempt, or the
    /// original bytes/mime — rather than throwing; the facade checks the byte
    /// cap and drops what still doesn't fit.
    func downscaled(
        _ data: Data,
        mimeType: String,
        target: KeepTalkingImageEncodingTarget
    ) -> (data: Data, mimeType: String)

    /// The pixel size of encoded image bytes, or nil when they can't be read.
    /// Optional for hosts: the default answers nil.
    func pixelSize(of data: Data) -> (width: Int, height: Int)?
}

/// Where a downscale should land. `maxBytes` counts the encoded binary, not
/// its base64; `AIImageInputPolicy` converts its wire budget into this.
public struct KeepTalkingImageEncodingTarget: Sendable, Hashable {
    public var maxPixelSize: Int
    public var maxBytes: Int?
    public var minPixelSize: Int
    public var minJPEGQuality: Double
    /// Types that may pass through as they are; empty accepts any image type.
    public var acceptedMIMETypes: Set<String>

    public init(
        maxPixelSize: Int,
        maxBytes: Int? = nil,
        minPixelSize: Int = 512,
        minJPEGQuality: Double = 0.5,
        acceptedMIMETypes: Set<String> = []
    ) {
        self.maxPixelSize = maxPixelSize
        self.maxBytes = maxBytes
        self.minPixelSize = min(minPixelSize, maxPixelSize)
        self.minJPEGQuality = minJPEGQuality
        self.acceptedMIMETypes = acceptedMIMETypes
    }

    public func accepts(mimeType: String) -> Bool {
        acceptedMIMETypes.isEmpty || acceptedMIMETypes.contains(mimeType.lowercased())
    }
}

extension KeepTalkingImageDownscaling {
    public func pixelSize(of data: Data) -> (width: Int, height: Int)? { nil }
}

/// Registry + facade for the host-provided image downscaler. Call sites use the
/// static `fitted` / `downscaledIfNeeded`; on platforms without a registered
/// downscaler the bytes pass through untouched when they already fit.
public enum KeepTalkingImageDownscaler {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: KeepTalkingImageDownscaling?

    /// Installs the host's image downscaler. Idempotent and safe to call before
    /// any image is processed; the most recent registration wins. Apple platforms
    /// register a CoreGraphics/ImageIO implementation — headless hosts can skip
    /// this and images simply pass through unchanged.
    public static func register(_ downscaler: KeepTalkingImageDownscaling) {
        lock.lock()
        defer { lock.unlock() }
        registered = downscaler
    }

    /// Normalisation for images entering a run's messages: wide enough for
    /// every provider policy, small enough that history and checkpoints don't
    /// carry camera-sized payloads. Connectors fit each request to their own
    /// `AIImageInputPolicy` on top of this.
    static let modelInputTarget = KeepTalkingImageEncodingTarget(
        maxPixelSize: 2048,
        maxBytes: 12 * 1024 * 1024,
        acceptedMIMETypes: AIImageInputPolicy.commonMIMETypes
    )

    /// `data` re-encoded to `target`, or nil when it still exceeds
    /// `target.maxBytes` (or, with no downscaler registered, is a type the
    /// target doesn't accept).
    static func fitted(
        _ data: Data,
        mimeType: String,
        target: KeepTalkingImageEncodingTarget
    ) -> (data: Data, mimeType: String)? {
        let output: (data: Data, mimeType: String)
        if let downscaler = registeredDownscaler() {
            output = downscaler.downscaled(data, mimeType: mimeType, target: target)
        } else {
            guard target.accepts(mimeType: mimeType) else { return nil }
            output = (data, mimeType)
        }
        if let maxBytes = target.maxBytes, output.data.count > maxBytes { return nil }
        return output
    }

    /// Longest side capped at `maxPixelSize`, nothing else asked for; the
    /// input comes back unchanged when that can't be done.
    static func downscaledIfNeeded(
        _ data: Data,
        mimeType: String,
        maxPixelSize: Int
    ) -> (data: Data, mimeType: String) {
        fitted(data, mimeType: mimeType, target: .init(maxPixelSize: maxPixelSize))
            ?? (data, mimeType)
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        registeredDownscaler()?.pixelSize(of: data)
    }

    private static func registeredDownscaler() -> KeepTalkingImageDownscaling? {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }
}
