import Foundation

/// Runs work strictly one-at-a-time per key, in call order.
///
/// Unlike `KeepTalkingContextSyncSingleFlight`, which coalesces concurrent
/// callers onto a single flight, every caller here gets its own run — they are
/// only kept from overlapping. Mark consumption needs exactly that: two syncs
/// completing at once must not interleave one's read of "what is unconsumed"
/// with the other's write of it, or the same projection applies twice.
///
/// One tail task is retained per key. Keys are contexts, so the map stays small
/// and is not pruned — a finished tail is just a completed `Task` to await.
actor KeepTalkingSerialGate {
    private var tails: [UUID: Task<Void, Never>] = [:]

    func run<T: Sendable>(
        for key: UUID,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = tails[key]
        let task = Task<Result<T, any Error>, Never> {
            await predecessor?.value
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        tails[key] = Task { _ = await task.value }
        return try await task.value.get()
    }
}
