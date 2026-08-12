import AppKit
import BlinkCore
import SwiftUI

@main
struct BlinkApp: App {
    @NSApplicationDelegateAdaptor(BlinkAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Blink", systemImage: "eye") {
            Toggle("In a meeting (manual)", isOn: Binding(
                get: { appDelegate.coordinator.isMeetingModeActive },
                set: { appDelegate.coordinator.setManuallyInMeeting($0) }
            ))
            Text(appDelegate.coordinator.isMeetingModeActive ? "Manual: On" : "Manual: Off")
                .foregroundStyle(.secondary)
            Text(appDelegate.coordinator.isCameraMeetingDetected
                 ? "Camera active — breaks suppressed"
                 : "Camera not in use")
                .foregroundStyle(.secondary)
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
            Toggle("Start at login", isOn: Binding(
                get: { appDelegate.coordinator.launchAtLogin },
                set: { appDelegate.coordinator.setLaunchAtLogin($0) }
            ))
            Divider()
            Menu("Updates") {
                Button(appDelegate.coordinator.updateStatus) {
                    appDelegate.coordinator.handleUpdateTap()
                }
                .disabled(!appDelegate.coordinator.canTapUpdate)
                Divider()
                Toggle("Automatically update", isOn: Binding(
                    get: { appDelegate.coordinator.autoUpdateEnabled },
                    set: { appDelegate.coordinator.setAutoUpdateEnabled($0) }
                ))
            }
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
        guard Self.terminateIfAlreadyRunning() else { return }

        coordinator.start()

        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Returns false and terminates this process if another instance of Blink is already running.
    private static func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }
        others.first?.activate()
        NSApp.terminate(nil)
        return false
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
    private var sharedContent: BreakOverlayContent?
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
    var isCameraMeetingDetected: Bool { meetingModeSource.isCameraActive }
    var intervalMinutes: Int { configuration.intervalSeconds / 60 }
    var deepSessionCapMinutes: Int { configuration.deepSessionCapSeconds / 60 }
    var snoozeLimit: Int { configuration.snoozeLimit }
    var launchAtLogin: Bool { LaunchAtLogin.isEnabled }
    private(set) var updateState: UpdateState = .notChecked
    private static let autoUpdateKey = "autoUpdateEnabled"
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60
    private var updateCheckTimer: Timer?

    var autoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    func setAutoUpdateEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.autoUpdateKey)
    }

    var updateStatus: String {
        switch updateState {
        case .notChecked: "Check for updates"
        case .checking: "Checking for updates..."
        case .upToDate: "Up to date"
        case .available(let info): "Update available: v\(info.version)"
        case .downloading(let info): "Downloading v\(info.version)..."
        case .downloaded(let info, _): "v\(info.version) ready — click to install and restart"
        case .failed: "Update failed, try again"
        }
    }

    var canTapUpdate: Bool {
        switch updateState {
        case .checking, .downloading: false
        default: true
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handle(.timeTick(.seconds(1))) }
        }
        typingActivityMonitor.start()
        cameraObserver.start()
        checkForUpdates()
        updateCheckTimer = .scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
    }

    func handleUpdateTap() {
        switch updateState {
        case .notChecked, .upToDate, .failed:
            checkForUpdates()
        case .available(let info):
            downloadUpdate(info)
        case .downloaded(_, let dmgURL):
            installUpdate(dmgURL)
        case .checking, .downloading:
            break
        }
    }

    private func checkForUpdates() {
        switch updateState {
        case .checking, .downloading: return
        default: break
        }
        updateState = .checking
        Task { [weak self] in
            guard let self else { return }
            if let info = await AppUpdater.checkForUpdate() {
                self.updateState = .available(info)
                if self.autoUpdateEnabled {
                    self.downloadUpdate(info)
                }
            } else {
                self.updateState = .upToDate
            }
        }
    }

    private func downloadUpdate(_ info: AppUpdateInfo) {
        updateState = .downloading(info)
        Task { [weak self] in
            guard let self else { return }
            do {
                let dmgURL = try await AppUpdater.download(info)
                self.updateState = .downloaded(info, dmgURL)
                if self.autoUpdateEnabled {
                    self.installUpdate(dmgURL)
                }
            } catch {
                self.updateState = .failed
            }
        }
    }

    private func installUpdate(_ dmgURL: URL) {
        do {
            try AppUpdater.install(dmgURL)
        } catch {
            updateState = .failed
        }
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
        let content = BreakOverlayContent(canSnooze: snoozesUsed < configuration.snoozeLimit)
        content.onComplete = { [weak self] in self?.completeBreak() }
        content.onSnoozeRequested = { [weak self] in self?.acceptSnooze() ?? false }
        content.onSnoozeCompleted = { [weak self] in self?.dismissForSnooze() }
        sharedContent = content
        overlays = NSScreen.screens.map { BreakOverlayWindow(screen: $0, content: content) }
        overlays.forEach { $0.show() }
    }

    private func completeBreak() {
        guard !overlays.isEmpty else { return }
        sharedContent?.stop()
        sharedContent = nil
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
        sharedContent?.stop()
        sharedContent = nil
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
    init(screen: NSScreen, content: BreakOverlayContent) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: BreakOverlayView(content: content))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.5
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }
}

@MainActor
@Observable
final class BreakOverlayContent {
    var secondsRemaining = 25
    var onComplete: (() -> Void)?
    var onSnoozeRequested: (() -> Bool)?
    var onSnoozeCompleted: (() -> Void)?
    var canSnooze: Bool
    private var timer: Timer?

    init(canSnooze: Bool) {
        self.canSnooze = canSnooze
    }

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

    func stopNow() {
        stop()
        onComplete?()
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

    private static let entrance = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.9)
    private static let tick = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.45)

    var body: some View {
        ZStack {
            backdrop
            card
        }
        .task { content.start() }
        .onAppear { visible = true }
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
        Group {
            if reduceTransparency {
                cardContent
                    .background(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .fill(Color(white: 0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 34, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            )
                    )
            } else {
                GlassEffectContainer {
                    cardContent
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.94)
        .blur(radius: visible ? 0 : 14)
        .animation(reduceMotion ? nil : Self.entrance, value: visible)
    }

    private var cardContent: some View {
        VStack(spacing: 28) {
            badge

            Text("\(content.secondsRemaining)")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    LinearGradient(colors: [.white, .white.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                )
                .contentTransition(.numericText(countsDown: true))
                .frame(minWidth: 170)
                .animation(reduceMotion ? nil : Self.tick, value: content.secondsRemaining)

            Text("Look away from your screens")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))

            Group {
                if content.canSnooze {
                    snoozeButton
                } else {
                    stopNowButton
                }
            }
            .padding(.top, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 56)
    }

    private var badge: some View {
        glassCapsule {
            Text("TIME FOR A BREAK")
                .font(.system(size: 11, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
    }

    private var snoozeButton: some View {
        Button {
            content.snooze()
        } label: {
            glassCapsule(interactive: true) {
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
            }
        }
        .buttonStyle(.plain)
    }

    private var stopNowButton: some View {
        Button {
            content.stopNow()
        } label: {
            glassCapsule(interactive: true) {
                HStack(spacing: 10) {
                    Text("Stop now")
                        .font(.system(size: 15, weight: .medium))
                    ZStack {
                        Circle().fill(.white.opacity(0.12))
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 26, height: 26)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 20)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func glassCapsule<Content: View>(interactive: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        if reduceTransparency {
            content()
                .background(.white.opacity(0.08), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        } else {
            content()
                .glassEffect(Glass.regular.interactive(interactive), in: .capsule)
        }
    }
}
