#if canImport(IrohLib)
import Foundation
import IrohLib
import Network

/// Network changes. iroh notices few by itself on Apple platforms, so the
/// host watches the system's network path and tells it. iroh then rebinds
/// its sockets, reconnects to the relay and finds new paths for every
/// connection, which carry on across the switch. What the host waits on
/// itself is cut short: the SFU retries now, and links that failed on the
/// old network redial.
extension KeepTalkingIrohTransportHost {
    /// Path updates come in bursts while interfaces settle; one change acts
    /// on the last of them.
    static let networkChangeSettle: Duration = .milliseconds(500)

    /// Tells the host the network may have changed. The host watches the
    /// system's network path itself; call this when the app returns from the
    /// background, which no path update announces. Harmless when nothing
    /// changed.
    public func networkChanged() {
        noteNetworkChange("app resumed")
    }

    func startPathMonitor() -> NWPathMonitor {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathUpdated(path)
        }
        monitor.start(queue: DispatchQueue(label: "KeepTalkingIrohTransportHost.path"))
        return monitor
    }

    private func pathUpdated(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ", ")
        let description = interfaces.isEmpty ? "\(path.status)" : "\(path.status) via \(interfaces)"
        let first = state.withLockedValue { state -> Bool in
            defer {
                state.path = description
                state.pathSatisfied = path.status == .satisfied
            }
            return state.path == nil
        }
        // The first update is the path the endpoint was bound on.
        guard !first else { return }
        noteNetworkChange(description)
    }

    /// Acts on the last of a burst of changes, once they settle.
    private func noteNetworkChange(_ reason: String) {
        let change = state.withLockedValue { state -> Int? in
            guard !state.isShutDown, state.endpoint != nil else { return nil }
            state.networkChanges += 1
            return state.networkChanges
        }
        guard let change else { return }
        Task {
            try? await Task.sleep(for: Self.networkChangeSettle, clock: clock)
            await recoverFromNetworkChange(change, reason: reason)
        }
    }

    private func recoverFromNetworkChange(_ change: Int, reason: String) async {
        let recovery = state.withLockedValue { state -> (Endpoint, AsyncStream<Void>.Continuation?)? in
            guard !state.isShutDown, state.networkChanges == change, let endpoint = state.endpoint else {
                return nil
            }
            state.table.clearBackoff()
            let bell = state.sfu.retryBell
            if bell == nil, case .connecting = state.sfu.status { state.sfu.retryNow = true }
            return (endpoint, bell)
        }
        guard let recovery else { return }
        let (endpoint, bell) = recovery
        log("network changed (\(reason)): rebinding")
        await endpoint.networkChange()
        bell?.yield()
        keepMeshLinks(now: clock.now)
    }
}
#endif
