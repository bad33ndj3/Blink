import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class TypingActivityMonitor {
    private let onTypingActivity: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onTypingActivity: @escaping () -> Void) {
        self.onTypingActivity = onTypingActivity
    }

    func start() {
        guard globalMonitor == nil else { return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in self?.onTypingActivity() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.onTypingActivity()
            return event
        }
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
    }
}
