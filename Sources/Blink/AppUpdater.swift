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

    /// Opens the downloaded DMG so the user finishes the existing drag-to-Applications flow.
    static func open(_ dmgURL: URL) {
        NSWorkspace.shared.open(dmgURL)
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
