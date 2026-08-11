public struct BreakScheduler {
    public struct Configuration: Sendable {
        public let interval: Duration
        public let breakDuration: Duration

        public init(interval: Duration, breakDuration: Duration) {
            self.interval = interval
            self.breakDuration = breakDuration
        }
    }

    public enum Event: Sendable {
        case timeTick(Duration)
        case breakCompleted
    }

    public enum Effect: Equatable, Sendable {
        case showBreak
    }

    private let configuration: Configuration
    private var elapsedSinceBreak = Duration.zero
    private var showingBreak = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .timeTick(let elapsed):
            guard !showingBreak else { return [] }
            elapsedSinceBreak += elapsed
            guard elapsedSinceBreak >= configuration.interval else { return [] }
            showingBreak = true
            return [.showBreak]

        case .breakCompleted:
            elapsedSinceBreak = .zero
            showingBreak = false
            return []
        }
    }
}
