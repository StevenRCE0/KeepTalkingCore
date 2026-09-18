import Foundation

/// A handle to one `observe` registration. Cancelling is explicit; a
/// subscription otherwise lives as long as the signal it was made on.
public struct KeepTalkingSignalSubscription: Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Removes the handler. Idempotent; a no-op once the signal is gone.
    public func cancel() {
        onCancel()
    }
}
