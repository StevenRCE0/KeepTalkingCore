#if canImport(IrohLib)
import Foundation
import IrohLib
import NIOConcurrencyHelpers

/// The process's one Bluetooth endpoint, lent to one transport host at a time.
///
/// `iroh-ble-transport` can't be torn down: closing the iroh endpoint leaves
/// its BLE stack — advertising, scanning, serving its GATT service — running
/// until the process exits, and blew can't remove services, so a rebound
/// endpoint would stack a second GATT table that a peer's subscribe could
/// land on (the pipe connected, carried nothing, drained after 45 s).
///
/// So the endpoint is bound once, with a key fixed for the process, and never
/// closed. A host `claim`s it while it wants Bluetooth and `release`s it
/// after; incoming connections go to the current holder and are refused
/// otherwise. With no holder the radio is paused — no scanning, no
/// advertising — and the next claim resumes it.
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
        /// The last pause/resume; each one waits for the one before.
        var radioSwitch: Task<Void, Never>?
        #if canImport(CoreBluetooth)
        var identityReader: KeepTalkingIrohBluetoothIdentityReader?
        #endif
    }

    private init() {
        let key = SecretKey.generate()
        secret = key.toBytes()
        endpointID = key.public().toBytes()
    }

    /// Lends the endpoint to `host`, binding it on first use and resuming the
    /// radio. Fails while another live host holds it.
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
            let endpoint = try await bind.value
            await switchRadio(endpoint, active: true).value
            return endpoint
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

    /// Gives the endpoint back; with no holder left the radio pauses.
    func release(from host: KeepTalkingIrohTransportHost) {
        let endpoint = state.withLockedValue { state -> Task<Endpoint, Error>? in
            guard state.holder === host else { return nil }
            state.holder = nil
            return state.bind
        }
        guard let endpoint else { return }
        Task {
            guard let endpoint = try? await endpoint.value else { return }
            _ = self.switchRadio(endpoint, active: false)
        }
    }

    /// Queues a pause or resume behind the previous one, so a release then
    /// claim can't end with the radio paused while held.
    private func switchRadio(_ endpoint: Endpoint, active: Bool) -> Task<Void, Never> {
        state.withLockedValue { state in
            let previous = state.radioSwitch
            let task = Task {
                await previous?.value
                // A claim may have come in since a release queued its pause.
                if !active, self.state.withLockedValue({ $0.holder != nil }) { return }
                try? await endpoint.bleSetRadioActive(active: active)
            }
            state.radioSwitch = task
            return task
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
