import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class PermissionSequence {
    private var activationObserver: NSObjectProtocol?

    func requestAccessibilityThenCamera(_ cameraObserver: CameraInUseObserver) {
        if AXIsProcessTrusted() {
            cameraObserver.start()
            return
        }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak cameraObserver] _ in
            Task { @MainActor [weak self, weak cameraObserver] in
                guard let self, let cameraObserver else { return }
                self.finish(with: cameraObserver)
            }
        }
    }

    private func finish(with cameraObserver: CameraInUseObserver) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        cameraObserver.start()
    }
}
