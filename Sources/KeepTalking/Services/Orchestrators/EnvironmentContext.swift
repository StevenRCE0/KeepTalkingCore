import Foundation

/// Shared builder for the environmental context every agent should be grounded
/// in — the local wall-clock time, the user's timezone, and the running
/// platform. Centralised so the main text agent and the audio bridge present
/// identical, correct facts (previously the main agent emitted a bare UTC
/// ISO-8601 timestamp with no timezone, and the audio bridge had none at all).
///
/// `now`/`timeZone` are injectable so callers can render deterministic output
/// in tests; production callers use the defaults.
enum KeepTalkingEnvironmentContext {
    /// Running platform, resolved at compile time.
    static var platform: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "unknown"
        #endif
    }

    /// e.g. `Saturday, 2026-06-06 14:23 (America/Los_Angeles, GMT-07:00)`.
    /// Fixed POSIX formatting so the representation is stable and unambiguous
    /// for the model regardless of the device's display locale.
    static func localDateTimeDescription(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let local = formatter.string(from: now)
        return "\(local) (\(timeZone.identifier), \(gmtOffsetString(timeZone: timeZone, now: now)))"
    }

    /// One-line summary suitable for embedding directly in a system prompt.
    static func summaryLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "Current date and time: \(localDateTimeDescription(now: now, timeZone: timeZone)). Platform: \(platform)."
    }

    private static func gmtOffsetString(timeZone: TimeZone, now: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: now)
        let sign = seconds >= 0 ? "+" : "-"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}
