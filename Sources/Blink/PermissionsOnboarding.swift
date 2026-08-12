import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import AVFoundation
import SwiftUI
import UserNotifications

enum PermissionKind: CaseIterable, Identifiable {
    case accessibility
    case camera
    case notifications

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .camera: "Camera"
        case .notifications: "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: "Needed to detect your typing activity and show breaks."
        case .camera: "Needed to detect whether you're in a video call."
        case .notifications: "Needed to remind you about a break."
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: "hand.raised"
        case .camera: "camera"
        case .notifications: "bell"
        }
    }

    fileprivate var settingsURL: URL {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .camera: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        }
    }
}

@MainActor
@Observable
final class PermissionsOnboardingModel {
    private(set) var granted: [PermissionKind: Bool] = [:]
    private var requested: Set<PermissionKind> = []

    var allGranted: Bool { PermissionKind.allCases.allSatisfy { granted[$0] == true } }

    func isGranted(_ kind: PermissionKind) -> Bool { granted[kind] ?? false }

    func refresh() async {
        for kind in PermissionKind.allCases {
            granted[kind] = await status(of: kind)
        }
    }

    func request(_ kind: PermissionKind) {
        guard !isGranted(kind) else { return }

        if requested.contains(kind) {
            NSWorkspace.shared.open(kind.settingsURL)
            return
        }
        requested.insert(kind)

        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in await self?.refresh() }
            }
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.refresh()
        }
    }

    private func status(of kind: PermissionKind) async -> Bool {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted()
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .notifications:
            return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        }
    }
}

struct OnboardingView: View {
    @State private var model = PermissionsOnboardingModel()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Blink")
                    .font(.title2.bold())
                Text("Blink needs a few permissions to be able to announce breaks.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, granted: model.isGranted(kind)) {
                        model.request(kind)
                    }
                }
            }

            Toggle("Automatically start Blink when your Mac starts up", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    LaunchAtLogin.setEnabled(enabled)
                }

            HStack {
                Spacer()
                Button("Done") { onFinish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 440)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let granted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).fontWeight(.medium)
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Button(granted ? "Granted" : "Request access") { onRequest() }
                .disabled(granted)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    convenience init(onFinish: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Blink"
        window.contentViewController = NSHostingController(rootView: OnboardingView(onFinish: onFinish))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }
}
