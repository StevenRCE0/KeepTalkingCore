#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// Process-wide sink for the Rust side's `tracing` output (iroh, the
/// Bluetooth transport), filtered per crate, so a lab can show what the
/// radio layer is doing on a device without a debugger attached.
///
/// Rust allows one global subscriber per process: the first `install`
/// wins and later calls return false.
@_spi(TransportLab)
public final class KeepTalkingIrohLog: LogSink, @unchecked Sendable {
    public static let shared = KeepTalkingIrohLog()
    /// Bluetooth transport and its BLE backend at debug, everything else at
    /// warn. blew's Apple central stays at info: its debug level logs every
    /// advert it hears.
    public static let bluetoothDirectives =
        "iroh_ble_transport=debug,blew=debug,blew::platform::apple::central=info,warn"

    private static let capacity = 600
    private struct Buffer {
        var lines: [String] = []
        var installed = false
        var total = 0
    }

    private let buffer = NIOLockedValueBox(Buffer())
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    public var isInstalled: Bool { buffer.withLockedValue { $0.installed } }

    /// Lines received since install, including any dropped from the buffer.
    public var totalLines: Int { buffer.withLockedValue { $0.total } }

    /// Installs the Rust subscriber with `directives` (`EnvFilter` syntax),
    /// also echoing to stderr (Xcode's console). Once per process.
    @discardableResult
    public func install(directives: String = KeepTalkingIrohLog.bluetoothDirectives, stderr: Bool = true) -> Bool {
        guard !isInstalled else { return false }
        let installed = setLogSink(directives: directives, sink: self, stderr: stderr)
        // A concurrent install that lost the race must not mark us
        // uninstalled after the winner succeeded.
        if installed { buffer.withLockedValue { $0.installed = true } }
        return installed
    }

    public func recent(_ count: Int = 200) -> [String] {
        buffer.withLockedValue { Array($0.lines.suffix(count)) }
    }

    public func clear() {
        buffer.withLockedValue { $0.lines.removeAll() }
    }

    // MARK: - LogSink

    public func line(line: String) {
        let stamped = "\(clock.string(from: Date())) \(line)"
        buffer.withLockedValue { buffer in
            buffer.total += 1
            buffer.lines.append(stamped)
            if buffer.lines.count > Self.capacity {
                buffer.lines.removeFirst(buffer.lines.count - Self.capacity)
            }
        }
    }
}
#endif
