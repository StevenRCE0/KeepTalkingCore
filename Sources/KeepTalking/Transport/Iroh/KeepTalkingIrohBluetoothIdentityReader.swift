#if canImport(IrohLib) && canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Reads the full Bluetooth endpoint id a nearby device serves in the iroh
/// GATT service's identity characteristic (a KeepTalking patch to the
/// vendored `iroh-ble-transport`).
///
/// Adverts carry only a 12-byte key prefix, which iroh can't dial; this is
/// how two devices that never met through the hub learn each other's id.
/// It runs its own `CBCentralManager`, so its short connections never touch
/// the transport's: CoreBluetooth shares the radio link between managers,
/// and cancelling ours leaves theirs up. Devices are named by the
/// identifiers the transport reports, which any manager in the app can
/// retrieve.
final class KeepTalkingIrohBluetoothIdentityReader: NSObject, @unchecked Sendable {
    /// `IROH_SERVICE_UUID` and `IROH_IDENTITY_CHAR_UUID` in the vendored crate.
    static var serviceUUID: CBUUID { CBUUID(string: "69726F01-8E45-4C2C-B3A5-331F3098B5C2") }
    static var identityUUID: CBUUID { CBUUID(string: "69726F06-8E45-4C2C-B3A5-331F3098B5C2") }
    static let identityLength = 32

    private let queue = DispatchQueue(label: "keeptalking.iroh.bluetooth-identity")
    private var manager: CBCentralManager?
    // Confined to `queue`.
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var reads: [UUID: Read] = [:]

    private struct Read {
        let token = UUID()
        let peripheral: CBPeripheral
        let continuation: CheckedContinuation<Data?, Never>
    }

    override init() {
        super.init()
        manager = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    /// The 32-byte endpoint id `deviceID` serves, or nil when the device is
    /// gone, serves none, or doesn't answer within `timeout`.
    func read(deviceID: String, timeout: Duration = .seconds(10)) async -> Data? {
        guard let identifier = UUID(uuidString: deviceID), await waitUntilPoweredOn() else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard self.reads[identifier] == nil,
                    let manager = self.manager,
                    let peripheral = manager.retrievePeripherals(withIdentifiers: [identifier]).first
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let read = Read(peripheral: peripheral, continuation: continuation)
                self.reads[identifier] = read
                peripheral.delegate = self
                manager.connect(peripheral)
                let token = read.token
                self.queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) {
                    if self.reads[identifier]?.token == token { self.finish(identifier, nil) }
                }
            }
        }
    }

    private func waitUntilPoweredOn() async -> Bool {
        let ready = await withCheckedContinuation { continuation in
            queue.async {
                if self.manager?.state == .poweredOn {
                    continuation.resume(returning: true)
                } else {
                    self.readyWaiters.append(continuation)
                    self.queue.asyncAfter(deadline: .now() + 5) { self.resumeWaiters(false) }
                }
            }
        }
        return ready
    }

    /// On `queue`.
    private func resumeWaiters(_ ready: Bool) {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(returning: ready) }
    }

    /// On `queue`. Idempotent: the first outcome wins.
    private func finish(_ identifier: UUID, _ value: Data?) {
        guard let read = reads.removeValue(forKey: identifier) else { return }
        read.peripheral.delegate = nil
        manager?.cancelPeripheralConnection(read.peripheral)
        read.continuation.resume(returning: value)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension KeepTalkingIrohBluetoothIdentityReader: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            resumeWaiters(true)
        } else if central.state != .unknown, central.state != .resetting {
            resumeWaiters(false)
            for identifier in Array(reads.keys) { finish(identifier, nil) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        finish(peripheral.identifier, nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        finish(peripheral.identifier, nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finish(peripheral.identifier, nil)
            return
        }
        peripheral.discoverCharacteristics([Self.identityUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.identityUUID }) else {
            finish(peripheral.identifier, nil)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == Self.identityUUID else { return }
        let value = characteristic.value.flatMap { $0.count == Self.identityLength ? $0 : nil }
        finish(peripheral.identifier, error == nil ? value : nil)
    }
}
#endif
