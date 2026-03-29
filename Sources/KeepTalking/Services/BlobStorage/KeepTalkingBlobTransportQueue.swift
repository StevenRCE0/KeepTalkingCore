import Foundation

actor KeepTalkingBlobTransportQueue {
    struct TransferDetails {
        var mask: Data?
        var recipients: Set<UUID>
    }

    private var pendingTransfers: [String: TransferDetails] = [:]
    private var isSending = false

    func enqueue(
        blobID: String,
        mask: Data?,
        recipient: UUID?
    ) {
        var details = pendingTransfers[blobID] ?? TransferDetails(mask: mask, recipients: [])

        // Merge masks. If any mask is nil, we default to sending all chunks (nil)
        if let currentMask = details.mask, let newMask = mask {
            details.mask = Self.mergeMasks(currentMask, newMask)
        } else {
            details.mask = nil
        }

        if let recipient {
            details.recipients.insert(recipient)
        }

        pendingTransfers[blobID] = details
    }

    func next() -> (blobID: String, details: TransferDetails)? {
        guard let key = pendingTransfers.keys.first else {
            isSending = false
            return nil
        }
        let details = pendingTransfers.removeValue(forKey: key)!
        return (key, details)
    }

    func markSending() -> Bool {
        if isSending { return true }
        isSending = true
        return false
    }

    private static func mergeMasks(_ lhs: Data, _ rhs: Data) -> Data {
        let count = max(lhs.count, rhs.count)
        var result = Data(count: count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            result[i] = l | r
        }
        return result
    }
}
