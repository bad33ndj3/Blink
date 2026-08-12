import AppKit
import Darwin
import Foundation

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct AppUpdateInfo: Equatable {
    let version: String
    let downloadURL: URL
}

enum UpdateState: Equatable {
    case notChecked
    case checking
    case upToDate
    case available(AppUpdateInfo)
    case downloading(AppUpdateInfo)
    case downloaded(AppUpdateInfo, URL)
    case failed
}

enum AppUpdater {
    private static let repo = "bad33ndj3/Blink"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Returns update info when the latest GitHub release is newer than the running app, nil otherwise (including on any network/parse failure).
    static func checkForUpdate() async -> AppUpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
        else { return nil }

        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard isVersion(latestVersion, newerThan: currentVersion) else { return nil }
        return AppUpdateInfo(version: latestVersion, downloadURL: asset.browserDownloadURL)
    }

    /// Downloads the release DMG and strips the quarantine flag Gatekeeper would otherwise
    /// block on. Does not open it — call `open(_:)` once the caller wants to act on it.
    static func download(_ info: AppUpdateInfo) async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(from: info.downloadURL)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Blink-\(info.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        destination.withUnsafeFileSystemRepresentation { path in
            _ = path.map { removexattr($0, "com.apple.quarantine", 0) }
        }
        return destination
    }

    enum InstallError: Error {
        case mountFailed
        case appNotFoundOnVolume
    }

    /// Mounts the DMG, copies the bundled `.app` over the running app's own bundle, and quits —
    /// a background relauncher script (which outlives this process) finishes the swap and reopens
    /// the app once this process exits, so there's no "in use" conflict from a manual Finder drag.
    @MainActor
    static func install(_ dmgURL: URL) throws {
        let mountPoint = try mountDMG(dmgURL)
        guard let sourceApp = try appBundle(onVolume: mountPoint) else {
            try? unmountDMG(mountPoint)
            throw InstallError.appNotFoundOnVolume
        }

        let destinationApp = Bundle.main.bundleURL
        let scriptURL = try writeRelauncherScript(
            pid: ProcessInfo.processInfo.processIdentifier,
            source: sourceApp,
            destination: destinationApp,
            mountPoint: mountPoint
        )

        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
        relauncher.arguments = [scriptURL.path]
        try relauncher.run()

        NSApp.terminate(nil)
    }

    private static func mountDMG(_ dmgURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgURL.path, "-nobrowse", "-noautoopen", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { throw InstallError.mountFailed }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw InstallError.mountFailed
    }

    private static func unmountDMG(_ mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        try process.run()
        process.waitUntilExit()
    }

    private static func appBundle(onVolume mountPoint: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        return contents.first { $0.pathExtension == "app" }
    }

    private static func writeRelauncherScript(pid: Int32, source: URL, destination: URL, mountPoint: URL) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-relaunch-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(shellQuote(destination.path))
        cp -R \(shellQuote(source.path)) \(shellQuote(destination.path))
        xattr -dr com.apple.quarantine \(shellQuote(destination.path)) 2>/dev/null || true
        hdiutil detach \(shellQuote(mountPoint.path)) -quiet
        open \(shellQuote(destination.path))
        rm -- "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }

    private static func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
