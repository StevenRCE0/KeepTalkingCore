import Foundation

extension KeepTalkingThread {
    public func resolvedMessageRange(
        in messages: [KeepTalkingContextMessage]
    ) -> ClosedRange<Int>? {
        guard !messages.isEmpty else {
            return nil
        }
        guard
            let startID = self.$startMessage.id,
            let startIndex = messages.firstIndex(where: { $0.id == startID })
        else {
            return nil
        }

        let endIndex: Int
        switch state {
            case .contextMain:
                endIndex = messages.count - 1
            case .stored, .archived:
                guard
                    let endID = self.$endMessage.id,
                    let idx = messages.firstIndex(where: { $0.id == endID })
                else {
                    return nil
                }
                endIndex = idx
        }

        guard startIndex <= endIndex else {
            return nil
        }
        return startIndex...endIndex
    }
}
