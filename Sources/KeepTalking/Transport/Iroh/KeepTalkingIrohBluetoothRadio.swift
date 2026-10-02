#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// The process's one Bluetooth endpoint, lent to one transport host at a time.
///
/// `iroh-ble-transport` 0.5.1 cannot shut down: closing the iroh endpoint
/// leaves its BLE stack running until the process exits — still advertising,
/// scanning and serving its GATT service — because the crate's watchdog and
/// event tasks keep its registry and CoreBluetooth managers alive. Binding a
/// fresh endpoint per gate cycle therefore stacked radios with identical
/// service UUIDs (and, with a reused key, identical adverts); a peer's GATT
/// subscribe could land on a dead stack, so the pipe connected, carried
/// nothing and drained after 45 s.
///
/// So the endpoint is bound once, with a key fixed for the process, and never
/// closed. A host `claim`s it while it wants Bluetooth and `release`s it
/// after; incoming connections go to the current holder and are refused
/// otherwise. The gate decides whether a host *uses* Bluetooth, not whether
/// the radio runs: once started, the radio stays on until the process exits.
/// Turning it off for real needs a crate-level shutdown.
final class KeepTalkingIrohBluetoothRadio: @unchecked Sendable {
    static let shared = KeepTalkingIrohBluetoothRadio()

    enum RadioError: LocalizedError {
        case inUse

        var errorDescription: String? {
            switch self {
                case .inUse: return "Bluetooth is in use by another transport host in this process."
            }
        }
    }

    /// Endpoint id of the Bluetooth endpoint, fixed for the process so the id
    /// a host announces in presence never goes stale.
    let endpointID: Data
    private let secret: Data
    private let state = NIOLockedValueBox(State())

    private struct State {
        var bind: Task<Endpoint, Error>?
        weak var holder: KeepTalkingIrohTransportHost?
        #if canImport(CoreBluetooth)
        var identityReader: KeepTalkingIrohBluetoothIdentityReader?
        #endif
    }

    private init() {
        let key = SecretKey.generate()
        secret = key.toBytes()
        endpointID = key.public().toBytes()
    }

    /// Lends the endpoint to `host`, binding it (and starting the radio) on
    /// first use. Fails while another live host holds it.
    func claim(for host: KeepTalkingIrohTransportHost) async throws -> Endpoint {
        let bind = try state.withLockedValue { state -> Task<Endpoint, Error> in
            if let holder = state.holder, holder !== host { throw RadioError.inUse }
            state.holder = host
            if let bind = state.bind { return bind }
            let bind = Task { try await self.bindEndpoint() }
            state.bind = bind
            return bind
        }
        do {
            return try await bind.value
        } catch {
            state.withLockedValue { state in
                state.bind = nil
                if state.holder === host { state.holder = nil }
            }
            throw error
        }
    }

    /// The full Bluetooth endpoint id a nearby device serves (see
    /// `KeepTalkingIrohBluetoothIdentityReader`); nil before the radio is up.
    func readIdentity(deviceID: String) async -> Data? {
        #if canImport(CoreBluetooth)
        guard let reader = state.withLockedValue({ $0.identityReader }) else { return nil }
        return await reader.read(deviceID: deviceID)
        #else
        return nil
        #endif
    }

    /// Gives the endpoint back. The radio keeps running.
    func release(from host: KeepTalkingIrohTransportHost) {
        state.withLockedValue { state in
            if state.holder === host { state.holder = nil }
        }
    }

    private func bindEndpoint() async throws -> Endpoint {
        let endpoint = try await Endpoint.bind(
            options: EndpointOptions(
                preset: presetMinimal(),
                secretKey: secret,
                alpns: [KeepTalkingIrohTransportHost.peerALPN],
                relayMode: RelayMode.disabled(),
                ble: true,
                clearIpTransports: true
            )
        )
        #if canImport(CoreBluetooth)
        let reader = KeepTalkingIrohBluetoothIdentityReader()
        state.withLockedValue { $0.identityReader = reader }
        #endif
        Task { await self.acceptLoop(endpoint) }
        return endpoint
    }

    private func acceptLoop(_ endpoint: Endpoint) async {
        while let incoming = await endpoint.acceptNext() {
            if let holder = state.withLockedValue({ $0.holder }) {
                holder.acceptBluetooth(incoming)
            } else {
                Task { try? await incoming.refuse() }
            }
        }
    }
}
#endif
