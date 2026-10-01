import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

final class ClickThroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayWindowManager {
    private struct ScreenOverlay {
        let displayID: CGDirectDisplayID
        let window: ClickThroughWindow
        let model: CRTGlitchModel
    }

    private var overlays: [ScreenOverlay] = []
    private var captures: [DisplayCapture] = []
    private var fallbackTimer: Timer?
    private var collapsing = false

    var windowIDs: [CGWindowID] {
        overlays.compactMap { overlay in
            let number = overlay.window.windowNumber
            guard number > 0 else { return nil }
            return CGWindowID(number)
        }
    }

    func present() {
        dismiss()
        collapsing = false
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let model = CRTGlitchModel()
            model.resetForGlitch()
            let window = ClickThroughWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CRTGlitchView(model: model))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays.append(ScreenOverlay(displayID: displayID, window: window, model: model))
        }
        startFallbackClock()
    }

    func startCapture() async -> Bool {
        guard !overlays.isEmpty else { return false }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard CGPreflightScreenCaptureAccess() else { return false }

        if windowIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        let excludedIDs = Set(windowIDs)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return false
        }

        var started = false
        for overlay in overlays {
            guard let display = content.displays.first(where: { $0.displayID == overlay.displayID }) else {
                continue
            }
            let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
            let capture = DisplayCapture(displayID: overlay.displayID)
            capture.onFrame = { [weak self] displayID, image in
                self?.show(image: image, on: displayID)
            }
            capture.onFailure = { [weak self] in
                self?.showFallback()
            }
            do {
                let screen = NSScreen.screens.first { $0.displayID == overlay.displayID }
                let scale = screen?.backingScaleFactor ?? 2
                try await capture.start(
                    display: display,
                    excluding: excluded,
                    pointSize: display.frame.size,
                    scale: scale
                )
                captures.append(capture)
                started = true
            } catch {
                continue
            }
        }
        return started
    }

    func showFallback() {
        for overlay in overlays where !collapsing {
            overlay.model.showsFallback = true
        }
    }

    func collapse(completion: @escaping () -> Void) {
        guard !collapsing else { return }
        collapsing = true
        stopCapture()
        stopFallbackClock()
        for overlay in overlays {
            overlay.model.phase = .collapsing
            overlay.model.collapseY = 0.008
            overlay.model.bloom = 0.9
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            self?.overlays.forEach { overlay in
                overlay.model.collapseX = 0.02
                overlay.model.bloom = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) { [weak self] in
            self?.overlays.forEach { $0.model.opacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.76) {
            completion()
        }
    }

    func dismiss() {
        stopCapture()
        stopFallbackClock()
        for overlay in overlays {
            overlay.window.orderOut(nil)
            overlay.window.close()
        }
        overlays.removeAll()
        collapsing = false
    }

    private func show(image: CGImage, on displayID: CGDirectDisplayID) {
        guard !collapsing, let overlay = overlays.first(where: { $0.displayID == displayID }) else { return }
        let size = NSSize(width: image.width, height: image.height)
        overlay.model.frame = NSImage(cgImage: image, size: size)
        overlay.model.showsFallback = false
    }

    private func startFallbackClock() {
        stopFallbackClock()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFallback()
            }
        }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceFallback() {
        guard !collapsing else { return }
        for overlay in overlays where overlay.model.showsFallback {
            overlay.model.fallbackTime += 1.0 / 30.0
        }
    }

    private func stopFallbackClock() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func stopCapture() {
        let current = captures
        captures.removeAll()
        Task {
            for capture in current {
                await capture.stop()
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    var onFrame: ((CGDirectDisplayID, CGImage) -> Void)?
    var onFailure: (() -> Void)?

    private let processor = GlitchFrameProcessor()
    private let queue = DispatchQueue(label: "com.smacktofix.capture")
    private let deliveryLock = NSLock()
    private var stream: SCStream?
    private var delivering = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func start(
        display: SCDisplay,
        excluding: [SCWindow],
        pointSize: CGSize,
        scale: CGFloat
    ) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        let configuration = SCStreamConfiguration()
        let pixelWidth = max(2, Int(pointSize.width * scale / 2))
        let pixelHeight = max(2, Int(pointSize.height * scale / 2))
        configuration.width = pixelWidth - pixelWidth % 2
        configuration.height = pixelHeight - pixelHeight % 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let image = processor.process(pixelBuffer: pixelBuffer) else { return }
        deliveryLock.lock()
        let busy = delivering
        if !busy {
            delivering = true
        }
        deliveryLock.unlock()
        guard !busy else { return }
        let displayID = displayID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock()
            self.delivering = false
            self.deliveryLock.unlock()
            self.onFrame?(displayID, image)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?()
        }
    }
}
