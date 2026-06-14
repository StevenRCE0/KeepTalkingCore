import Foundation

/// Resizes an oversized image before it is handed to a model. LLM vision
/// endpoints reject or heavily down-sample huge images (and bill by resolution),
/// so the longest side is capped at `maxPixelSize`, preserving aspect ratio.
///
/// The concrete implementation relies on Apple imaging frameworks
/// (CoreGraphics/ImageIO), which aren't available on every platform the SDK
/// targets (e.g. the headless Linux/Windows daemon). The SDK therefore only
/// owns the *seam*: a host registers a downscaler via
/// `KeepTalkingImageDownscaler.register(_:)`, and image handling falls back to a
/// pass-through when none is registered. Apple hosts (the app) inject a
/// CoreGraphics/ImageIO backed implementation at launch.
public protocol KeepTalkingImageDownscaling: Sendable {
    /// Returns a copy capped at `maxPixelSize` on the longest side, preserving
    /// aspect ratio, or the input unchanged when no resize is needed or possible.
    /// Implementations MUST fail open — returning the original bytes/mime — rather
    /// than throwing, so a decode/encode hiccup never blocks the message.
    func downscaledIfNeeded(
        _ data: Data,
        mimeType: String,
        maxPixelSize: Int
    ) -> (data: Data, mimeType: String)
}

/// Registry + facade for the host-provided image downscaler. Call sites use the
/// static `downscaledIfNeeded` exactly as before; on platforms without a
/// registered downscaler the bytes pass through untouched (fail-open).
public enum KeepTalkingImageDownscaler {
    /// Longest-side cap, in pixels, for images handed to a model.
    public static let maxPixelSize = 4000

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

    static func downscaledIfNeeded(
        _ data: Data,
        mimeType: String,
        maxPixelSize: Int = maxPixelSize
    ) -> (data: Data, mimeType: String) {
        lock.lock()
        let downscaler = registered
        lock.unlock()
        guard let downscaler else { return (data, mimeType) }
        return downscaler.downscaledIfNeeded(
            data, mimeType: mimeType, maxPixelSize: maxPixelSize)
    }
}
