import AppKit
import BlinkCore
import SwiftUI

@main
struct BlinkApp: App {
    @NSApplicationDelegateAdaptor(BlinkAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Blink", systemImage: "eye") {
            Toggle("In a meeting", isOn: Binding(
                get: { appDelegate.coordinator.isMeetingModeActive },
                set: { appDelegate.coordinator.setManuallyInMeeting($0) }
            ))
            Divider()
            Stepper("Interval: \(appDelegate.coordinator.intervalMinutes) min", value: Binding(
                get: { appDelegate.coordinator.intervalMinutes },
                set: { appDelegate.coordinator.setIntervalMinutes($0) }
            ), in: 1...180)
            Stepper("Deep Session Cap: \(appDelegate.coordinator.deepSessionCapMinutes) min", value: Binding(
                get: { appDelegate.coordinator.deepSessionCapMinutes },
                set: { appDelegate.coordinator.setDeepSessionCapMinutes($0) }
            ), in: 1...480)
            Stepper("Snoozes: \(appDelegate.coordinator.snoozeLimit)", value: Binding(
                get: { appDelegate.coordinator.snoozeLimit },
                set: { appDelegate.coordinator.setSnoozeLimit($0) }
            ), in: 0...3)
            Divider()
            Menu("Debug") {
                Button("Trigger Now") { appDelegate.coordinator.triggerBreakNow() }
            }
            Divider()
            Button("Permissions...") { appDelegate.showOnboarding() }
            Divider()
            Button("Quit Blink") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class BlinkAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = BreakCoordinator()
    private var onboardingWindowController: OnboardingWindowController?

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()

        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                self?.onboardingWindowController?.close()
                self?.onboardingWindowController = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class BreakCoordinator {
    private var configuration: BlinkConfiguration
    private var scheduler: BreakScheduler
    private var timer: Timer?
    private var overlays: [BreakOverlayWindow] = []
    private var snoozesUsed = 0
    @ObservationIgnored private lazy var typingActivityMonitor = TypingActivityMonitor { [weak self] in
        self?.handle(.typingActivity)
    }
    @ObservationIgnored private lazy var meetingModeSource = MeetingModeSource { [weak self] active in
        self?.handle(active ? .meetingModeEntered : .meetingModeExited)
    }
    @ObservationIgnored private lazy var cameraObserver = CameraInUseObserver { [weak self] active in
        self?.meetingModeSource.setCameraActive(active)
    }

    init() {
        let configuration = BlinkConfiguration.load()
        self.configuration = configuration
        scheduler = BreakScheduler(configuration: Self.schedulerConfiguration(from: configuration))
    }

    var isMeetingModeActive: Bool { meetingModeSource.isManuallyActive }
    var intervalMinutes: Int { configuration.intervalSeconds / 60 }
    var deepSessionCapMinutes: Int { configuration.deepSessionCapSeconds / 60 }
    var snoozeLimit: Int { configuration.snoozeLimit }

    func start() {
        guard timer == nil else { return }
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handle(.timeTick(.seconds(1))) }
        }
        typingActivityMonitor.start()
        cameraObserver.start()
        LaunchAtLogin.register()
    }

    func triggerBreakNow() {
        showBreak()
    }

    private func handle(_ event: BreakScheduler.Event) {
        for effect in scheduler.handle(event) {
            switch effect {
            case .showBreak: showBreak()
            case .showNudge: NudgeNotifier.show()
            }
        }
    }

    private func showBreak() {
        if !overlays.isEmpty {
            overlays.forEach { $0.dismiss() }
        }
        overlays = NSScreen.screens.map { screen in
            BreakOverlayWindow(
                screen: screen,
                completion: { [weak self] in self?.completeBreak() },
                acceptSnooze: { [weak self] in self?.acceptSnooze() ?? false },
                dismissForSnooze: { [weak self] in self?.dismissForSnooze() }
            )
        }
        overlays.forEach { $0.show() }
    }

    private func completeBreak() {
        guard !overlays.isEmpty else { return }
        overlays.forEach { $0.dismiss() }
        overlays = []
        snoozesUsed = 0
        handle(.breakCompleted)
    }

    private func acceptSnooze() -> Bool {
        guard !overlays.isEmpty, snoozesUsed < configuration.snoozeLimit else { return false }
        snoozesUsed += 1
        handle(.snoozeRequested)
        return true
    }

    private func dismissForSnooze() {
        overlays.forEach { $0.dismiss() }
        overlays = []
    }

    func setManuallyInMeeting(_ active: Bool) {
        meetingModeSource.setManuallyActive(active)
    }

    func setIntervalMinutes(_ minutes: Int) {
        configuration.intervalSeconds = minutes * 60
        applyConfiguration()
    }

    func setDeepSessionCapMinutes(_ minutes: Int) {
        configuration.deepSessionCapSeconds = minutes * 60
        applyConfiguration()
    }

    func setSnoozeLimit(_ limit: Int) {
        configuration.snoozeLimit = limit
        applyConfiguration()
    }

    private func applyConfiguration() {
        scheduler.update(configuration: Self.schedulerConfiguration(from: configuration))
        try? configuration.save()
    }

    private static func schedulerConfiguration(from configuration: BlinkConfiguration) -> BreakScheduler.Configuration {
        .init(
            interval: .seconds(configuration.intervalSeconds),
            breakDuration: .seconds(25),
            typingDebounce: .seconds(5),
            deepSessionCap: .seconds(configuration.deepSessionCapSeconds),
            snoozeDelay: .seconds(5 * 60),
            snoozeLimit: configuration.snoozeLimit
        )
    }
}

@MainActor
final class BreakOverlayWindow: NSPanel {
    private let content = BreakOverlayContent()
    private var completion: (() -> Void)?

    init(
        screen: NSScreen,
        completion: @escaping () -> Void,
        acceptSnooze: @escaping () -> Bool,
        dismissForSnooze: @escaping () -> Void
    ) {
        self.completion = completion
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: BreakOverlayView(content: content))
        content.onComplete = { [weak self] in self?.completion?() }
        content.onSnoozeRequested = { [weak self] in self?.acceptSnooze?() ?? false }
        content.onSnoozeCompleted = { [weak self] in self?.dismissForSnooze?() }
        self.acceptSnooze = acceptSnooze
        self.dismissForSnooze = dismissForSnooze
    }

    private var acceptSnooze: (() -> Bool)?
    private var dismissForSnooze: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 2.5
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        content.stop()
        close()
    }
}

@MainActor
@Observable
final class BreakOverlayContent {
    var secondsRemaining = 25
    var onComplete: (() -> Void)?
    var onSnoozeRequested: (() -> Bool)?
    var onSnoozeCompleted: (() -> Void)?
    var canSnooze = true
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        secondsRemaining -= 1
        guard secondsRemaining == 0 else { return }
        stop()
        onComplete?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func snooze() {
        guard canSnooze else { return }
        guard onSnoozeRequested?() == true else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            canSnooze = false
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.onSnoozeCompleted?()
        }
    }
}

struct BreakOverlayView: View {
    @Bindable var content: BreakOverlayContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var visible = false
    @State private var pulse = false

    private static let entrance = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.9)
    private static let tick = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.45)

    var body: some View {
        ZStack {
            backdrop
            card
        }
        .task { content.start() }
        .onAppear { visible = true }
        .onChange(of: content.secondsRemaining) { _, _ in pulseCountdown() }
    }

    /// Decoded once and reused — `body` re-evaluates every countdown tick, and re-decoding
    /// this file from disk each time was visibly janking the timer.
    ///
    /// `Bundle.module` resolves relative to `Bundle.main.bundleURL`, which for a packaged
    /// `.app` is its top-level directory. Our packaging script places resource bundles in the
    /// conventional `Contents/Resources` location instead, so look there first.
    private static let backdropImage: Image = {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Blink_Blink.bundle"),
           let bundle = Bundle(url: resourceURL),
           let fileURL = bundle.url(forResource: "WWDC26_Mac", withExtension: "jpg"),
           let nsImage = NSImage(contentsOf: fileURL) {
            return Image(nsImage: nsImage)
        }
        if let fileURL = Bundle.module.url(forResource: "WWDC26_Mac", withExtension: "jpg"),
           let nsImage = NSImage(contentsOf: fileURL) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "moon.stars")
    }()

    private var backdrop: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                Color.black.ignoresSafeArea()

                Self.backdropImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .clipped()

                // Vignette to seat the card in a darker, more legible center.
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.55)],
                    center: .center, startRadius: w * 0.2, endRadius: w * 0.62
                )
            }
        }
        .ignoresSafeArea()
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? nil : Self.entrance, value: visible)
    }

    private var card: some View {
        VStack(spacing: 28) {
            Text("TIJD VOOR EEN PAUZE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.white.opacity(0.08), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))

            Text("\(content.secondsRemaining)")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.white, .white.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                )
                .contentTransition(.numericText(countsDown: true))
                .scaleEffect(pulse ? 1.05 : 1)
                .animation(reduceMotion ? nil : Self.tick, value: content.secondsRemaining)

            Text("Kijk weg van je schermen")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))

            if content.canSnooze {
                snoozeButton.padding(.top, 8)
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 56)
        .background(innerCore)
        .padding(6)
        .background(outerShell)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.94)
        .blur(radius: visible ? 0 : 14)
        .animation(reduceMotion ? nil : Self.entrance, value: visible)
    }

    private var innerCore: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(reduceTransparency ? AnyShapeStyle(Color(white: 0.08)) : AnyShapeStyle(.ultraThinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .white.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }

    private var outerShell: some View {
        RoundedRectangle(cornerRadius: 40, style: .continuous)
            .fill(.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var snoozeButton: some View {
        Button {
            content.snooze()
        } label: {
            HStack(spacing: 10) {
                Text("Snooze")
                    .font(.system(size: 15, weight: .medium))
                ZStack {
                    Circle().fill(.white.opacity(0.12))
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(width: 26, height: 26)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.leading, 20)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .scaleEffect(1)
        .animation(reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.3), value: content.canSnooze)
    }

    private func pulseCountdown() {
        guard !reduceMotion else { return }
        pulse = true
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            pulse = false
        }
    }
}
