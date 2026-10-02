#if canImport(IrohLib)
import Foundation
import IrohLib

/// Upkeep and Bluetooth: the once-a-second maintenance pass, the network
/// gate, lending and returning the process-wide Bluetooth endpoint, and
/// finding nearby devices without the SFU.
extension KeepTalkingIrohTransportHost {
    // MARK: - Maintenance

    /// Once a second: forgets members nothing has reached for
    /// `memberRetention`, closes accepted links that never showed a shared
    /// context, ends an SFU session whose writes stalled, runs the Bluetooth
    /// gate and offline discovery.
    func maintenanceLoop() async {
        while !Task.isCancelled, !state.withLockedValue({ $0.isShutDown }) {
            let now = clock.now
            sweep(now: now)
            keepMeshLinks(now: now)
            if let stalled = stalledSFU(now: now) {
                log("SFU writes stalled for \(Self.sfuStallTimeout); reconnecting")
                try? stalled.close(errorCode: 1, reason: Data("stalled".utf8))
            }
            if configuration.bluetooth != .off {
                runBluetoothGate(now: now)
                discoverNearby(at: now)
            }
            try? await Task.sleep(for: .seconds(1), clock: clock)
        }
    }

    private func sweep(now: Instant) {
        let (departures, orphans) = mutateLinks(touching: nil) {
            state -> ([(KeepTalkingIrohMembership.Departure, KeepTalkingIrohAttachment?)], [LinkIO]) in
            let table = state.table
            let departures = state.membership.sweep(
                now: now,
                retention: Self.memberRetention,
                reachable: table.isCarrying
            ).map { ($0, state.attachments[$0.topic]?.sink) }
            let wanted = state
            let unproven = state.table.unproven(now: now, grace: Self.acceptGrace, wanted: wanted.isWanted)
            state.table.pruneBackoff(now: now)
            state.bluetooth.probeRetryAt = state.bluetooth.probeRetryAt.filter { $0.value > now }
            let orphans = state.dropUnneededLinks(among: departures.flatMap(\.0.unlink) + unproven)
            return (departures, orphans)
        }
        orphans.forEach { Self.tearDown($0, reason: "unneeded") }
        for (departure, sink) in departures {
            log("member \(departure.nodeID.uuidString.prefix(8)) unreached for \(Self.memberRetention): forgotten")
            sink?.memberLeft(departure.nodeID)
        }
    }

    /// Dials members of rooms on the mesh, and members something demanded a
    /// link to, that have none yet; forgets expired demands. Rooms move
    /// between the mesh and the SFU as they grow, shrink, or the SFU comes
    /// and goes, so this runs every pass rather than only on learning.
    func keepMeshLinks(now: Instant) {
        let targets = state.withLockedValue { state -> [(Data, LinkKind)] in
            state.demand = state.demand.filter { $0.value > now }
            let mains = state.meshMembers.union(state.demand.keys)
            return mains.flatMap { main -> [(Data, LinkKind)] in
                var targets: [(Data, LinkKind)] = []
                if state.table.links[main] == nil { targets.append((main, .network)) }
                if let bluetooth = state.membership.bluetoothID(of: main), state.table.links[bluetooth] == nil {
                    targets.append((bluetooth, .bluetooth))
                }
                return targets
            }
        }
        for (id, kind) in targets { ensureLink(to: id, kind: kind) }
    }

    /// Holds the Bluetooth endpoint always, or while the network gate is open.
    private func runBluetoothGate(now: Instant) {
        let (wanted, running, flipped) = state.withLockedValue { state -> (Bool, Bool, Bool?) in
            let failing = state.networkFailure != nil
            let flipped = state.bluetooth.gate.update(failing: failing, now: now)
            let wanted = configuration.bluetooth == .always || state.bluetooth.gate.isOpen
            return (wanted, state.bluetooth.endpoint != nil || state.bluetooth.starting, flipped)
        }
        if let flipped { log(flipped ? "network gate open" : "network gate closed") }
        if wanted, !running {
            log("claiming bluetooth")
            Task { await self.startBluetooth() }
        } else if !wanted, running {
            log("releasing bluetooth")
            stopBluetooth()
        }
    }

    // MARK: - Bluetooth endpoint

    private func startBluetooth() async {
        let proceed = state.withLockedValue { state -> Bool in
            guard !state.isShutDown, state.bluetooth.endpoint == nil, !state.bluetooth.starting else {
                return false
            }
            state.bluetooth.starting = true
            return true
        }
        guard proceed else { return }
        do {
            let endpoint = try await KeepTalkingIrohBluetoothRadio.shared.claim(for: self)
            let targets = state.withLockedValue { state -> Set<Data>? in
                state.bluetooth.starting = false
                // Shut down while claiming: hand the radio straight back.
                guard !state.isShutDown else { return nil }
                state.bluetooth.endpoint = endpoint
                state.bluetooth.failure = nil
                state.bluetooth.starts += 1
                return state.membership.bluetoothIDs
            }
            guard let targets else {
                KeepTalkingIrohBluetoothRadio.shared.release(from: self)
                return
            }
            log("bluetooth endpoint \(Self.hex(endpoint.id().toBytes()).prefix(10)) claimed")
            for target in targets { ensureLink(to: target, kind: .bluetooth) }
        } catch {
            let changed = state.withLockedValue { state -> Bool in
                state.bluetooth.starting = false
                defer { state.bluetooth.failure = error.localizedDescription }
                return state.bluetooth.failure != error.localizedDescription
            }
            if changed { log("bluetooth unavailable: \(error.localizedDescription)") }
        }
    }

    /// Drops our Bluetooth links and lends the endpoint back; with no other
    /// holder the radio pauses.
    private func stopBluetooth() {
        let closing = mutateLinks(touching: nil) { state -> [LinkIO] in
            state.bluetooth.endpoint = nil
            let ids = state.table.links.filter { $0.value.kind == .bluetooth }.map(\.key)
            return ids.compactMap { id in
                state.table.remove(id)
                state.outbound.remove(Self.linkQueue(id))
                return state.io.removeValue(forKey: id)
            }
        }
        closing.forEach { Self.tearDown($0, reason: "bluetooth off") }
        KeepTalkingIrohBluetoothRadio.shared.release(from: self)
        log("bluetooth endpoint released")
    }

    // MARK: - Offline discovery

    /// Finds nearby KeepTalking devices without the SFU. Adverts carry a
    /// 12-byte key prefix, which can't be dialled, so the full id is read
    /// from the device (`KeepTalkingIrohBluetoothIdentityReader`) — only for
    /// devices we're due to dial, whose prefix sorts below ours (the higher
    /// Bluetooth id dials). A dialled device is wanted until its hello shows
    /// we share no context. One read at a time.
    private func discoverNearby(at now: Instant) {
        guard
            let bluetooth = state.withLockedValue({ state -> (endpoint: Endpoint, myID: Data)? in
                guard let endpoint = state.bluetooth.endpoint, let myID = state.bluetooth.myID else { return nil }
                return (endpoint, myID)
            })
        else { return }
        let devices: [(deviceID: String, prefix: Data)] = (bluetooth.endpoint.bleStatus()?.peers ?? []).compactMap {
            peer in
            peer.prefix.flatMap(Self.bytes(fromHex:)).map { (peer.deviceId, $0) }
        }
        let myPrefix = bluetooth.myID.prefix(Self.bluetoothPrefixLength)
        let (probe, redial) = state.withLockedValue { state -> ((String, Data)?, [Data]) in
            // Devices that stopped advertising are no longer worth a dial.
            let present = Set(devices.map(\.prefix))
            for id in state.bluetooth.nearby.keys where !present.contains(id.prefix(Self.bluetoothPrefixLength)) {
                state.bluetooth.nearby[id] = nil
            }
            let redial = state.bluetooth.nearby.keys.filter {
                !state.bluetooth.strangers.contains($0) && state.table.links[$0] == nil
            }
            guard !state.bluetooth.probing else { return (nil, redial) }
            let known = Set(
                (Array(state.membership.bluetoothIDs) + Array(state.bluetooth.nearby.keys))
                    .map { Data($0.prefix(Self.bluetoothPrefixLength)) }
            )
            let probe = devices.first { device in
                device.prefix.lexicographicallyPrecedes(myPrefix) && !known.contains(device.prefix)
                    && (state.bluetooth.probeRetryAt[device.deviceID].map { $0 <= now } ?? true)
            }
            if probe != nil { state.bluetooth.probing = true }
            return (probe, redial)
        }
        for id in redial { ensureLink(to: id, kind: .bluetooth) }
        guard let probe else { return }
        let (deviceID, prefix) = probe
        Task { [self] in
            let id = await KeepTalkingIrohBluetoothRadio.shared.readIdentity(deviceID: deviceID)
            // The id must be the one the device advertises half of.
            let verified = id.flatMap { $0.prefix(Self.bluetoothPrefixLength) == prefix ? $0 : nil }
            let retryAt = clock.now + Self.identityRetryAfter
            state.withLockedValue { state in
                state.bluetooth.probing = false
                if let verified {
                    state.bluetooth.nearby[verified] = deviceID
                    state.bluetooth.probeRetryAt[deviceID] = nil
                } else {
                    state.bluetooth.probeRetryAt[deviceID] = retryAt
                }
            }
            if let verified {
                log("nearby \(Self.hex(verified).prefix(10)) identified over Bluetooth")
                ensureLink(to: verified, kind: .bluetooth)
            } else {
                log("nearby device \(deviceID.prefix(8)) did not serve an identity")
            }
        }
    }
}
#endif
