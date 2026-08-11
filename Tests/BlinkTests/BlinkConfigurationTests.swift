@testable import Blink
import Foundation
import Testing

struct BlinkConfigurationTests {
    @Test func loadsPartialYamlAndKeepsDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "blink-config-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try "intervalSeconds: 300\nsnoozeLimit: 2".write(to: url, atomically: true, encoding: .utf8)

        #expect(BlinkConfiguration.load(from: url) == .init(intervalSeconds: 300, snoozeLimit: 2))
    }

    @Test func savesYamlThatLoadsAgain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "blink-config-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = BlinkConfiguration(intervalSeconds: 900, deepSessionCapSeconds: 1_800, snoozeLimit: 0)

        try configuration.save(to: url)
        #expect(BlinkConfiguration.load(from: url) == configuration)
    }
}
