import AppKit
import BlinkCore
@preconcurrency import ApplicationServices
import SwiftUI

@main
struct BlinkApp: App {
    private let coordinator = BreakCoordinator()

    init() {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }

    var body: some Scene {
        MenuBarExtra("Blink", systemImage: "eye") {
            Text("Look-away breaks are active")
            Button("Quit Blink") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
@Observable
final class BreakCoordinator {
    private var scheduler = BreakScheduler(configuration: .init(
        interval: .seconds(20 * 60),
        breakDuration: .seconds(25)
    ))
    private var timer: Timer?
    private var overlays: [BreakOverlayWindow] = []
    private let inputBlocker = InputBlocker()

    func start() {
        guard timer == nil else { return }
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handle(.timeTick(.seconds(1))) }
        }
    }

    private func handle(_ event: BreakScheduler.Event) {
        guard scheduler.handle(event).contains(.showBreak) else { return }
        showBreak()
    }

    private func showBreak() {
        inputBlocker.start()
        overlays = NSScreen.screens.map { screen in
            BreakOverlayWindow(screen: screen) { [weak self] in self?.completeBreak() }
        }
        overlays.forEach { $0.show() }
    }

    private func completeBreak() {
        guard !overlays.isEmpty else { return }
        overlays.forEach { $0.dismiss() }
        overlays = []
        inputBlocker.stop()
        handle(.breakCompleted)
    }
}

@MainActor
final class BreakOverlayWindow: NSPanel {
    private let content = BreakOverlayContent()
    private var completion: (() -> Void)?

    init(screen: NSScreen, completion: @escaping () -> Void) {
        self.completion = completion
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: BreakOverlayView(content: content))
        content.onComplete = { [weak self] in self?.completion?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
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
}

struct BreakOverlayView: View {
    @Bindable var content: BreakOverlayContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glassNamespace
    @State private var visible = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GlassEffectContainer {
                VStack(spacing: 20) {
                    Text("\\(content.secondsRemaining)")
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                    Text("Look away from your screens")
                        .font(.title2)
                }
                .padding(56)
                .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(corners: .concentric))
                .glassEffectID("break-card", in: glassNamespace)
            }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.96)
        }
        .task { content.start() }
        .onAppear { visible = true }
        .animation(reduceMotion ? nil : .spring(response: 0.9, dampingFraction: 0.85), value: visible)
    }
}

@MainActor
final class InputBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return }
        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
                                         .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ in
                type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
                    ? Unmanaged.passUnretained(event)
                    : nil
            },
            userInfo: nil
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        runLoopSource = nil
    }
}
