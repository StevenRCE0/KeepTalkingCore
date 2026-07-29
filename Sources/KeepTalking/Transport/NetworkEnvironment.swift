import Crypto
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fingerprint of this node's local network vantage point.
///
/// Every "direct does not work here" verdict the transport reaches — the mesh
/// cap tripping, a channel exhausting its failure budget into `.abandoned` — is
/// only valid for the environment that produced it. Move the node to another
/// network and those verdicts are stale, but nothing in the transport notices a
/// move: the mesh flag clears only on a full restart, and an abandoned channel
/// revives only on a per-peer reachability edge. Comparing this digest across
/// heartbeats turns the move itself into the trigger.
///
/// IPv6 addresses contribute only their /64 prefix. The prefix identifies the
/// network; the host bits rotate on their own under RFC 4941 privacy
/// addressing, so digesting the whole address would churn on a stationary node
/// and re-arm the very retry paths this is meant to gate.
public enum KeepTalkingNetworkEnvironment {
    /// Stable digest of the up, non-loopback interface addresses.
    ///
    /// Returns a constant on platforms without `getifaddrs`, which degrades to
    /// the previous behaviour — no environment-change detection — rather than
    /// reporting a spurious change on every sample.
    public static func digest() -> String {
        let entries = interfaceEntries()
        guard !entries.isEmpty else { return "unavailable" }
        var hasher = SHA256()
        for entry in entries.sorted() {
            hasher.update(data: Data(entry.utf8))
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private static func interfaceEntries() -> [String] {
        #if canImport(Darwin) || canImport(Glibc)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var entries: [String] = []
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard
                flags & UInt32(IFF_UP) != 0,
                flags & UInt32(IFF_LOOPBACK) == 0,
                let address = current.pointee.ifa_addr
            else { continue }

            let name = String(cString: current.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let raw = address.withMemoryRebound(
                        to: sockaddr_in.self,
                        capacity: 1
                    ) { $0.pointee.sin_addr.s_addr }
                    entries.append("\(name)/4/\(raw)")
                case AF_INET6:
                    let prefix = address.withMemoryRebound(
                        to: sockaddr_in6.self,
                        capacity: 1
                    ) { pointer -> [UInt8] in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) {
                            Array($0.prefix(8))
                        }
                    }
                    let rendered =
                        prefix
                        .map { String(format: "%02x", $0) }
                        .joined()
                    entries.append("\(name)/6/\(rendered)")
                default:
                    continue
            }
        }
        return entries
        #else
        return []
        #endif
    }
}
