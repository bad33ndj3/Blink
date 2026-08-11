import BlinkCore
import Testing

struct BreakSchedulerTests {
    private let config = BreakScheduler.Configuration(
        interval: .seconds(20 * 60),
        breakDuration: .seconds(25),
        typingDebounce: .seconds(5),
        deepSessionCap: .seconds(30 * 60),
        snoozeDelay: .seconds(60),
        snoozeLimit: 1
    )

    @Test func doesNotShowBreakBeforeTheInterval() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.timeTick(.seconds(20 * 60 - 1))) == [])
    }

    @Test func showsBreakWhenTheIntervalElapses() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.timeTick(.seconds(20 * 60))) == [.showBreak])
    }

    @Test func resetsTheIntervalAfterBreakCompletes() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.timeTick(.seconds(20 * 60))) == [.showBreak])
        #expect(scheduler.handle(.breakCompleted) == [])
        #expect(scheduler.handle(.timeTick(.seconds(20 * 60 - 1))) == [])
        #expect(scheduler.handle(.timeTick(.seconds(1))) == [.showBreak])
    }

    @Test func typingPostponesABreakUntilTheNextIdleTick() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.timeTick(.seconds(20 * 60 - 1))) == [])
        #expect(scheduler.handle(.typingActivity) == [])
        #expect(scheduler.handle(.timeTick(.seconds(1))) == [])
        #expect(scheduler.handle(.timeTick(.seconds(4))) == [.showBreak])
    }

    @Test func deepSessionCapFiresDespiteContinuedTyping() {
        let capConfig = BreakScheduler.Configuration(
            interval: .seconds(1),
            breakDuration: config.breakDuration,
            typingDebounce: config.typingDebounce,
            deepSessionCap: .seconds(3),
            snoozeDelay: config.snoozeDelay,
            snoozeLimit: config.snoozeLimit
        )
        var scheduler = BreakScheduler(configuration: capConfig)

        #expect(scheduler.handle(.typingActivity) == [])
        #expect(scheduler.handle(.timeTick(.seconds(1))) == [])
        #expect(scheduler.handle(.typingActivity) == [])
        #expect(scheduler.handle(.timeTick(.seconds(1))) == [])
        #expect(scheduler.handle(.typingActivity) == [])
        #expect(scheduler.handle(.timeTick(.seconds(1))) == [.showBreak])
    }

    @Test func snoozePostponesOnlyOncePerBreak() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.timeTick(config.interval)) == [.showBreak])
        #expect(scheduler.handle(.snoozeRequested) == [])
        #expect(scheduler.handle(.snoozeRequested) == [])
        #expect(scheduler.handle(.timeTick(.seconds(59))) == [])
        #expect(scheduler.handle(.timeTick(.seconds(1))) == [.showBreak])
    }

    @Test func meetingSilencesOnceThenNudgesWithoutShowingABreak() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.meetingModeEntered) == [])
        #expect(scheduler.handle(.timeTick(config.deepSessionCap)) == [])
        #expect(scheduler.handle(.timeTick(config.deepSessionCap)) == [.showNudge])
    }

    @Test func meetingModeSuppressesAnExpiredSnooze() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.timeTick(config.interval)) == [.showBreak])
        #expect(scheduler.handle(.snoozeRequested) == [])
        #expect(scheduler.handle(.meetingModeEntered) == [])
        #expect(scheduler.handle(.timeTick(config.snoozeDelay)) == [])
        #expect(scheduler.handle(.timeTick(config.interval)) == [.showNudge])
    }

    @Test func leavingMeetingModeRestoresBreaksAtTheNextTrigger() {
        var scheduler = BreakScheduler(configuration: config)

        #expect(scheduler.handle(.meetingModeEntered) == [])
        #expect(scheduler.handle(.timeTick(config.interval)) == [])
        #expect(scheduler.handle(.meetingModeExited) == [])
        #expect(scheduler.handle(.timeTick(config.interval)) == [.showBreak])
    }
}
