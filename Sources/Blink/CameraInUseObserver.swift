import AVFoundation

@MainActor
final class CameraInUseObserver {
    private let onChange: (Bool) -> Void
    private var observation: NSKeyValueObservation?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            observeCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                Task { @MainActor in self?.observeCamera() }
            }
        default:
            onChange(false)
        }
    }

    func stop() {
        observation = nil
        onChange(false)
    }

    private func observeCamera() {
        guard observation == nil, let camera = AVCaptureDevice.default(for: .video) else {
            onChange(false)
            return
        }
        observation = camera.observe(\.isInUseByAnotherApplication, options: [.initial, .new]) { [weak self] device, _ in
            let active = device.isInUseByAnotherApplication
            Task { @MainActor in self?.onChange(active) }
        }
    }
}
