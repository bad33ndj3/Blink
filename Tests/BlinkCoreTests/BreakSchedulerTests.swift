import BlinkCore
import Testing

struct BreakSchedulerTests {
    private let config = BreakScheduler.Configuration(
        interval: .seconds(20 * 60),
        breakDuration: .seconds(25)
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
}
