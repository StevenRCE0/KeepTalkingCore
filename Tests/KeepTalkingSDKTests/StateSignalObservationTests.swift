import Foundation
import Observation
import Testing

@testable import KeepTalkingSDK

/// `KeepTalkingStateSignal` is `Observable`: reading `current` under tracking
/// registers a dependency that a value-changing `send` invalidates.
struct StateSignalObservationTests {
    @Test("tracking `current` is invalidated by send")
    func sendInvalidates() async {
        let signal = KeepTalkingStateSignal<Int>(0)
        let fired = SignalRecorder<Int>()
        withObservationTracking {
            _ = signal.current
        } onChange: {
            fired.record(signal.current)
        }

        signal.send(1)

        await fired.waitForCount(1)
        // `onChange` runs after the write, so an observer that re-reads sees the new value.
        #expect(fired.snapshot == [1])
        #expect(signal.current == 1)
    }

    @Test("an unchanged send(ifChanged:) leaves observers alone; a changed one fires")
    func ifChangedInvalidatesOnlyOnChange() async {
        let signal = KeepTalkingStateSignal<Int>(3)
        let fired = SignalRecorder<Bool>()
        withObservationTracking {
            _ = signal.current
        } onChange: {
            fired.record(true)
        }

        #expect(signal.send(ifChanged: 3) == false)
        await fired.settle()
        #expect(fired.snapshot.isEmpty)

        #expect(signal.send(ifChanged: 4) == true)
        await fired.waitForCount(1)
        #expect(fired.snapshot == [true])
    }

    @Test("observation does not disturb FIFO delivery or replay")
    func observationLeavesSubscribersIntact() async {
        let signal = KeepTalkingStateSignal<Int>(0)
        let values = SignalRecorder<Int>()
        signal.observe { values.record($0) }
        withObservationTracking {
            _ = signal.current
        } onChange: {
        }

        for value in 1...5 { signal.send(value) }

        await values.waitForCount(6)
        #expect(values.snapshot == [0, 1, 2, 3, 4, 5])
    }

    @Test("an observer may read `current` from onChange without deadlocking")
    func onChangeMayReadCurrent() async {
        let signal = KeepTalkingStateSignal<String>("a")
        let seen = SignalRecorder<String>()
        withObservationTracking {
            _ = signal.current
        } onChange: {
            seen.record(signal.current)  // would hang if notified inside the lock
        }

        signal.send("b")

        await seen.waitForCount(1)
        #expect(seen.snapshot == ["b"])
    }
}
