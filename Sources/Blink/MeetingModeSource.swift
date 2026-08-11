import Foundation

@MainActor
final class MeetingModeSource {
    private(set) var isManuallyActive = false
    private(set) var isCameraActive = false
    private let onChange: (Bool) -> Void

    var isActive: Bool { isManuallyActive || isCameraActive }

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func setManuallyActive(_ active: Bool) {
        isManuallyActive = active
        notifyIfChanged()
    }

    func setCameraActive(_ active: Bool) {
        isCameraActive = active
        notifyIfChanged()
    }

    private func notifyIfChanged() {
        let active = isActive
        guard active != lastReportedState else { return }
        lastReportedState = active
        onChange(active)
    }

    private var lastReportedState = false
}
