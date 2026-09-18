import Foundation
import Testing

@testable import KeepTalkingSDK

struct KeepTalkingSignalTests {
    @Test("every subscriber receives every value, in emission order")
    func fifoMulticast() async {
        let signal = KeepTalkingSignal<Int>()
        let first = SignalRecorder<Int>()
        let second = SignalRecorder<Int>()
        signal.observe { first.record($0) }
        signal.observe { second.record($0) }

        for value in 0..<200 { signal.send(value) }

        await first.waitForCount(200)
        await second.waitForCount(200)
        #expect(first.snapshot == Array(0..<200))
        #expect(second.snapshot == Array(0..<200))
    }

    @Test("observeOnMain runs the handler on the main actor, in emission order")
    func observeOnMainHopsToMainActor() async {
        let signal = KeepTalkingSignal<Int>()
        let values = SignalRecorder<Int>()
        let onMainThread = SignalRecorder<Bool>()
        signal.observeOnMain { value in
            onMainThread.record(isOnMainThread())
            values.record(value)
        }

        for value in 0..<50 { signal.send(value) }

        await values.waitForCount(50)
        #expect(values.snapshot == Array(0..<50))
        #expect(onMainThread.snapshot.allSatisfy { $0 })
    }

    @Test("observeOnMain on a state signal replays current first")
    func observeOnMainReplaysState() async {
        let signal = KeepTalkingStateSignal<Int>(7)
        let values = SignalRecorder<Int>()
        signal.observeOnMain { values.record($0) }
        signal.send(8)

        await values.waitForCount(2)
        #expect(values.snapshot == [7, 8])
    }

    @Test("a cancelled subscription receives nothing sent after the cancel")
    func cancelStopsDelivery() async {
        let signal = KeepTalkingSignal<Int>()
        let recorder = SignalRecorder<Int>()
        let subscription = signal.observe { recorder.record($0) }

        signal.send(1)
        await recorder.waitForCount(1)
        subscription.cancel()
        signal.send(2)
        await recorder.settle()

        #expect(recorder.snapshot == [1])
    }

    @Test("a values stream ends when its task is cancelled")
    func streamEndsOnTaskCancel() async {
        let signal = KeepTalkingSignal<Int>()
        let stream = signal.values
        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        signal.send(1)
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()

        #expect(await withTimeout { await consumer.value } == 1)
    }

    @Test("a values stream ends when the signal is released")
    func streamEndsWhenSignalReleased() async {
        var signal: KeepTalkingSignal<Int>? = KeepTalkingSignal<Int>()
        let stream = signal!.values
        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        signal!.send(1)
        signal!.send(2)
        signal = nil

        #expect(await withTimeout { await consumer.value } == 2)
    }

    @Test("a state signal replays its current value first, then updates")
    func stateReplay() async {
        let signal = KeepTalkingStateSignal(7)
        let recorder = SignalRecorder<Int>()
        signal.observe { recorder.record($0) }
        await recorder.waitForCount(1)
        #expect(recorder.snapshot == [7])

        signal.send(8)
        await recorder.waitForCount(2)
        #expect(recorder.snapshot == [7, 8])
        #expect(signal.current == 8)

        let stream = signal.values
        let firstFromStream = await withTimeout {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(firstFromStream == 8)
    }

    @Test("replay never reorders against concurrent sends")
    func replayOrdersAgainstConcurrentSends() async {
        let signal = KeepTalkingStateSignal(0)
        let producer = Task {
            for value in 1...2000 {
                signal.send(value)
                if value % 50 == 0 { await Task.yield() }
            }
        }
        var recorders: [SignalRecorder<Int>] = []
        for _ in 0..<20 {
            let recorder = SignalRecorder<Int>()
            signal.observe { recorder.record($0) }
            recorders.append(recorder)
            await Task.yield()
        }
        await producer.value

        for recorder in recorders {
            await recorder.waitForCount(1)
            // Wait until this recorder saw the final value.
            let deadline = ContinuousClock.now + .seconds(5)
            while recorder.snapshot.last != 2000, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let seen = recorder.snapshot
            // Replay is the value current at subscribe time, and every later
            // emission follows with none skipped or repeated.
            #expect(seen.last == 2000)
            #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 + 1 == $1 })
        }
    }

    @Test("send(ifChanged:) skips equal values")
    func sendIfChangedDedupes() async {
        let signal = KeepTalkingStateSignal("a")
        let recorder = SignalRecorder<String>()
        signal.observe { recorder.record($0) }
        await recorder.waitForCount(1)

        #expect(signal.send(ifChanged: "a") == false)
        #expect(signal.send(ifChanged: "b") == true)
        await recorder.waitForCount(2)
        await recorder.settle()
        #expect(recorder.snapshot == ["a", "b"])
    }
}

/// `Thread.isMainThread` is `noasync`; reading it through a synchronous
/// helper is the sanctioned way to observe it from a `@MainActor` handler.
private func isOnMainThread() -> Bool { Thread.isMainThread }
