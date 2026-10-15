import Foundation
import Testing

@testable import PlayerCore
@testable import PlayerCore

@Suite("SleepTimer")
@MainActor
struct SleepTimerTests {
    @Test("starting a preset sets the full duration")
    func startSetsFullDuration() {
        let timer = SleepTimer()
        timer.start(preset: .fiveMinutes)
        #expect(timer.remainingSecs == 300)
        #expect(timer.isActive)
    }

    @Test("ticking counts down and does not fire onExpire before zero")
    func tickCountsDown() {
        let timer = SleepTimer()
        var expired = false
        timer.onExpire = { expired = true }
        timer.start(secs: 10)

        timer.tick(bySecs: 4)

        #expect(timer.remainingSecs == 6)
        #expect(!expired)
    }

    @Test("reaching zero fires onExpire exactly once and clears state")
    func reachingZeroFiresOnExpire() {
        let timer = SleepTimer()
        var expireCount = 0
        timer.onExpire = { expireCount += 1 }
        timer.start(secs: 5)

        timer.tick(bySecs: 5)

        #expect(timer.remainingSecs == nil)
        #expect(!timer.isActive)
        #expect(expireCount == 1)

        // A tick after expiry must be a no-op — nothing left to count down.
        timer.tick(bySecs: 1)
        #expect(expireCount == 1)
    }

    @Test("an overshooting tick still fires exactly once")
    func overshootingTickStillFiresOnce() {
        let timer = SleepTimer()
        var expireCount = 0
        timer.onExpire = { expireCount += 1 }
        timer.start(secs: 5)

        timer.tick(bySecs: 100)

        #expect(timer.remainingSecs == nil)
        #expect(expireCount == 1)
    }

    @Test("extend adds time to an active countdown")
    func extendAddsTime() {
        let timer = SleepTimer()
        timer.start(secs: 60)
        timer.tick(bySecs: 50) // 10s left

        timer.extend(bySecs: 600)

        #expect(timer.remainingSecs == 610)
    }

    @Test("extend after expiry is a no-op")
    func extendAfterExpiryIsNoOp() {
        let timer = SleepTimer()
        timer.start(secs: 5)
        timer.tick(bySecs: 5)

        timer.extend(bySecs: 300)

        #expect(timer.remainingSecs == nil)
    }

    @Test("cancel clears state and stops future ticks from firing onExpire")
    func cancelClearsState() {
        let timer = SleepTimer()
        var expired = false
        timer.onExpire = { expired = true }
        timer.start(secs: 5)

        timer.cancel()

        #expect(timer.remainingSecs == nil)
        #expect(!timer.isActive)

        timer.tick(bySecs: 100) // nothing to count down — must not fire
        #expect(!expired)
    }

    @Test("starting again while already running replaces the countdown")
    func startingAgainReplacesCountdown() {
        let timer = SleepTimer()
        timer.start(secs: 60)
        timer.tick(bySecs: 10)
        #expect(timer.remainingSecs == 50)

        timer.start(preset: .fifteenMinutes)

        #expect(timer.remainingSecs == 900)
    }

    // MARK: - End of episode

    @Test("arming for the end of the item is active but has no countdown")
    func endOfItemHasNoCountdown() {
        let timer = SleepTimer()
        timer.startUntilEndOfItem()
        #expect(timer.stopsAtEndOfItem)
        #expect(timer.remainingSecs == nil)
        #expect(timer.isActive)
    }

    /// The engine asks once, at the moment everything loaded has played out.
    @Test("the finish is consumed once, and disarms the timer")
    func consumesTheFinishOnce() {
        let timer = SleepTimer()
        timer.startUntilEndOfItem()
        #expect(timer.consumeEndOfItem())
        #expect(!timer.stopsAtEndOfItem)
        #expect(!timer.isActive)
        #expect(!timer.consumeEndOfItem(), "a second finish is not this timer's business")
    }

    @Test("an unarmed timer never claims a finish — auto-advance must still run")
    func doesNotConsumeWhenUnarmed() {
        let timer = SleepTimer()
        #expect(!timer.consumeEndOfItem())
        timer.start(secs: 60)
        #expect(!timer.consumeEndOfItem())
    }

    /// Picking one mode replaces the other, in both directions.
    @Test("the two modes are exclusive")
    func modesAreExclusive() {
        let timer = SleepTimer()
        timer.start(secs: 300)
        timer.startUntilEndOfItem()
        #expect(timer.remainingSecs == nil)

        timer.start(preset: .fiveMinutes)
        #expect(!timer.stopsAtEndOfItem)
        #expect(timer.remainingSecs == 300)
    }

    @Test("cancelling disarms the end-of-episode mode too")
    func cancelDisarms() {
        let timer = SleepTimer()
        timer.startUntilEndOfItem()
        timer.cancel()
        #expect(!timer.stopsAtEndOfItem)
        #expect(!timer.isActive)
    }

    /// Extending is a countdown operation; there is nothing to extend here.
    @Test("extending does nothing while armed for the end of the item")
    func extendIsANoOp() {
        let timer = SleepTimer()
        timer.startUntilEndOfItem()
        timer.extend(bySecs: 600)
        #expect(timer.remainingSecs == nil)
        #expect(timer.stopsAtEndOfItem)
    }
}
