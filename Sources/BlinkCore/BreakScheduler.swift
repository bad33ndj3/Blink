public struct BreakScheduler {
    public struct Configuration: Sendable {
        public let interval: Duration
        public let breakDuration: Duration
        public let typingDebounce: Duration
        public let deepSessionCap: Duration
        public let snoozeDelay: Duration
        public let snoozeLimit: Int

        public init(
            interval: Duration,
            breakDuration: Duration,
            typingDebounce: Duration = .seconds(5),
            deepSessionCap: Duration = .seconds(30 * 60),
            snoozeDelay: Duration = .seconds(60),
            snoozeLimit: Int = 1
        ) {
            self.interval = interval
            self.breakDuration = breakDuration
            self.typingDebounce = typingDebounce
            self.deepSessionCap = deepSessionCap
            self.snoozeDelay = snoozeDelay
            self.snoozeLimit = snoozeLimit
        }
    }

    public enum Event: Sendable {
        case timeTick(Duration)
        case typingActivity
        case meetingModeEntered
        case meetingModeExited
        case snoozeRequested
        case breakCompleted
    }

    public enum Effect: Equatable, Sendable {
        case showBreak
        case showNudge
    }

    private var configuration: Configuration
    private var elapsedSinceBreak = Duration.zero
    private var showingBreak = false
    private var elapsedSinceTyping: Duration?
    private var meetingModeActive = false
    private var hasSilencedMeetingTrigger = false
    private var snoozesUsed = 0
    private var snoozeRemaining: Duration?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public mutating func update(configuration: Configuration) {
        self.configuration = configuration
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .timeTick(let elapsed):
            if let snoozeRemaining {
                let remaining = snoozeRemaining - elapsed
                guard remaining > .zero else {
                    self.snoozeRemaining = nil
                    return triggerBreak()
                }
                self.snoozeRemaining = remaining
                return []
            }
            guard !showingBreak else { return [] }
            elapsedSinceBreak += elapsed
            if let elapsedSinceTyping {
                self.elapsedSinceTyping = elapsedSinceTyping + elapsed
            }
            guard elapsedSinceBreak >= configuration.interval else {
                return []
            }
            guard elapsedSinceBreak >= configuration.deepSessionCap || elapsedSinceTyping == nil || elapsedSinceTyping! >= configuration.typingDebounce else {
                return []
            }
            return triggerBreak()

        case .typingActivity:
            elapsedSinceTyping = .zero
            return []

        case .meetingModeEntered:
            meetingModeActive = true
            hasSilencedMeetingTrigger = false
            return []

        case .meetingModeExited:
            meetingModeActive = false
            return []

        case .snoozeRequested:
            guard showingBreak, snoozesUsed < configuration.snoozeLimit else { return [] }
            snoozesUsed += 1
            showingBreak = false
            snoozeRemaining = configuration.snoozeDelay
            return []

        case .breakCompleted:
            elapsedSinceBreak = .zero
            showingBreak = false
            elapsedSinceTyping = nil
            snoozesUsed = 0
            snoozeRemaining = nil
            return []
        }
    }

    private mutating func triggerBreak() -> [Effect] {
        if meetingModeActive {
            elapsedSinceBreak = .zero
            if hasSilencedMeetingTrigger {
                return [.showNudge]
            }
            hasSilencedMeetingTrigger = true
            return []
        }
        showingBreak = true
        return [.showBreak]
    }
}
