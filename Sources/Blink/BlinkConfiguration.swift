import Foundation

struct BlinkConfiguration: Equatable, Sendable {
    var intervalSeconds: Int = 20 * 60
    var deepSessionCapSeconds: Int = 60 * 60
    var snoozeLimit: Int = 1

    static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Blink", directoryHint: .isDirectory)
        .appending(path: "config.yaml")

    static func load(from url: URL = defaultURL) -> Self {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .init() }
        var configuration = Self()

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let value = Int(parts[1].split(separator: "#", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)),
                  value >= 0 else { continue }
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "intervalSeconds" where value > 0: configuration.intervalSeconds = value
            case "deepSessionCapSeconds" where value > 0: configuration.deepSessionCapSeconds = value
            case "snoozeLimit": configuration.snoozeLimit = value
            default: break
            }
        }
        return configuration
    }

    func save(to url: URL = Self.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let yaml = """
        intervalSeconds: \(intervalSeconds)
        deepSessionCapSeconds: \(deepSessionCapSeconds)
        snoozeLimit: \(snoozeLimit)
        """
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }
}
