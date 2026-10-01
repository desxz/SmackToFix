import AppKit
import AVFoundation
import Carbon

@main
enum SmackToFixMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var session: GlitchSession?
    private var menu: MenuBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let session = GlitchSession()
        let menu = MenuBarController(session: session)
        session.attach(menu: menu)
        session.start()
        self.session = session
        self.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.shutdown()
    }
}

@MainActor
final class GlitchSession: NSObject, NSWindowDelegate {
    private let detector = ImpactDetector()
    private let audio: CRTAudio
    private let overlay = OverlayWindowManager()
    private let backdoor = EscapeBackdoor()
    private let sensitivityModel = SensitivityModel()
    private var sensitivityPanel: SensitivityTestPanel?
    private var phase: Phase = .idle
    private var timer: Timer?
    private var timeoutTask: Task<Void, Never>?
    private let launchedAt = Date()
    private var sensitivityOpen = false
    private weak var menu: MenuBarController?

    override init() {
        audio = CRTAudio(engine: detector.engine)
        super.init()
        detector.outputPrepare = { [weak audio] in
            audio?.attach()
        }
    }

    private enum Phase {
        case idle
        case glitching
        case collapsing
    }

    func attach(menu: MenuBarController) {
        self.menu = menu
    }

    func start() {
        sensitivityModel.onThreshold = { [weak self] value in
            AppSettings.threshold = value
            self?.detector.threshold = value
        }
        detector.onImpact = { [weak self] in
            Task { @MainActor in
                self?.handleImpact()
            }
        }
        detector.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.sensitivityModel.apply(level: level)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        backdoor.onPress = { [weak self] in
            self?.closeFromBackdoor()
        }
        backdoor.install()
        scheduleNext()
    }

    func closeFromBackdoor() {
        switch phase {
        case .glitching:
            beginCollapse()
        case .collapsing:
            timeoutTask?.cancel()
            overlay.dismiss()
            finishCollapse()
        case .idle:
            break
        }
    }

    func shutdown() {
        timer?.invalidate()
        timeoutTask?.cancel()
        detector.stop()
        audio.stop()
        overlay.dismiss()
    }

    func trigger() {
        guard phase == .idle else { return }
        phase = .glitching
        menu?.setInteraction(busy: true, canAdmit: true)
        timer?.invalidate()
        if sensitivityOpen {
            sensitivityPanel?.close()
        }
        overlay.present()
        armTimeout()
        Task {
            await armSensors(resetDetector: true)
            if phase == .glitching {
                audio.startBuzz()
            }
        }
    }

    func admitDefeat() {
        beginCollapse()
    }

    func openSensitivityTest() {
        guard phase == .idle else { return }
        if sensitivityPanel == nil {
            let panel = SensitivityTestPanel(model: sensitivityModel)
            panel.delegate = self
            sensitivityPanel = panel
        }
        sensitivityOpen = true
        sensitivityModel.microphoneDenied = false
        sensitivityModel.inputProblem = nil
        sensitivityModel.heardPackets = 0
        sensitivityModel.peak = 0
        sensitivityPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await armSensors(resetDetector: true) }
    }

    func rescheduleIfIdle() {
        guard phase == .idle else { return }
        scheduleNext()
    }

    func windowWillClose(_ notification: Notification) {
        sensitivityOpen = false
        if phase == .idle {
            detector.stop()
        }
    }

    @objc private func screensChanged() {
        guard phase == .glitching else { return }
        beginCollapse()
    }

    private func armSensors(resetDetector: Bool) async {
        let mic = await PermissionCenter.microphoneAccess()
        sensitivityModel.microphoneDenied = !mic
        if mic {
            detector.threshold = AppSettings.threshold
            do {
                try detector.start(resetHistory: resetDetector)
                sensitivityModel.inputProblem = nil
                // The grant callback returns before the HAL will feed this engine.
                // start() succeeds and the meter stays on "Waiting…" until the
                // engine is stopped and started again, which is what closing and
                // reopening the test panel does by hand.
                scheduleSilentMicrophoneRetry(resetDetector: resetDetector)
            } catch {
                sensitivityModel.inputProblem = "Microphone graph didn't start."
            }
        }
        guard phase == .glitching else { return }
        let captured = await overlay.startCapture()
        if !captured {
            overlay.showFallback()
        }
    }

    private func scheduleSilentMicrophoneRetry(resetDetector: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard sensitivityModel.heardPackets == 0, sensitivityModel.inputProblem == nil else { return }
            guard !sensitivityModel.microphoneDenied else { return }
            let listening = (sensitivityOpen && phase == .idle) || phase == .glitching
            guard listening else { return }
            detector.stop()
            do {
                try detector.start(resetHistory: resetDetector)
                if phase == .glitching {
                    audio.startBuzz()
                }
            } catch {
                sensitivityModel.inputProblem = "Microphone graph didn't start."
            }
        }
    }

    private func handleImpact() {
        sensitivityModel.flash()
        guard phase == .glitching else { return }
        beginCollapse()
    }

    private func beginCollapse() {
        guard phase == .glitching else { return }
        phase = .collapsing
        timeoutTask?.cancel()
        audio.playPopAndStopBuzz()
        menu?.setInteraction(busy: true, canAdmit: false)
        overlay.collapse { [weak self] in
            self?.finishCollapse()
        }
    }

    private func finishCollapse() {
        guard phase != .idle else { return }
        overlay.dismiss()
        audio.stop()
        if !sensitivityOpen {
            detector.stop()
        }
        phase = .idle
        menu?.setInteraction(busy: false, canAdmit: false)
        scheduleNext()
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 75_000_000_000)
            guard !Task.isCancelled else { return }
            self.beginCollapse()
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let range = AppSettings.intervalRange(for: AppSettings.frequency)
        let delay = Double.random(in: range)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timerFired()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func timerFired() {
        guard phase == .idle else { return }
        if Date().timeIntervalSince(launchedAt) < 30 {
            scheduleNext()
            return
        }
        trigger()
    }
}

private enum PermissionCenter {
    static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

/// Option-Escape. Carbon hotkeys work while the app is not focused, without an Accessibility prompt.
final class EscapeBackdoor {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(target, { _, _, userData in
            guard let userData else { return noErr }
            let backdoor = Unmanaged<EscapeBackdoor>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                backdoor.onPress?()
            }
            return noErr
        }, 1, &spec, userdata, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x534D4B58), id: 1)
        RegisterEventHotKey(53, UInt32(1 << 11), hotKeyID, target, 0, &hotKey)
    }
}
