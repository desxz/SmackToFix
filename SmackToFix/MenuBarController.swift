import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let triggerItem = NSMenuItem(title: "Trigger Glitch Now", action: #selector(triggerGlitch), keyEquivalent: "g")
    private let sensitivityItem = NSMenuItem(title: "Test Slap Sensitivity…", action: #selector(testSensitivity), keyEquivalent: "t")
    private let admitItem = NSMenuItem(title: "Close Glitch (⌥⎋)", action: #selector(admitDefeat), keyEquivalent: "")
    private let frequencyCaption = NSTextField(labelWithString: "")
    private let frequencySlider = NSSlider(value: AppSettings.frequency, minValue: 0, maxValue: 1, target: nil, action: nil)
    private weak var session: GlitchSession?

    init(session: GlitchSession) {
        self.session = session
        super.init()
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "sMACk"
        statusItem.isVisible = true
        triggerItem.target = self
        sensitivityItem.target = self
        admitItem.target = self
        admitItem.isEnabled = false

        let menu = NSMenu()
        let title = NSMenuItem(title: "sMACk", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(triggerItem)
        menu.addItem(sensitivityItem)
        menu.addItem(.separator())
        menu.addItem(frequencyItem())
        menu.addItem(.separator())
        menu.addItem(admitItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateFrequencyCaption()
    }

    func setInteraction(busy: Bool, canAdmit: Bool) {
        admitItem.isEnabled = canAdmit
        triggerItem.isEnabled = !busy
        sensitivityItem.isEnabled = !busy
    }

    private func frequencyItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        frequencyCaption.frame = NSRect(x: 16, y: 30, width: 228, height: 16)
        frequencyCaption.font = NSFont.systemFont(ofSize: 12)
        frequencyCaption.textColor = .secondaryLabelColor
        frequencySlider.frame = NSRect(x: 16, y: 8, width: 228, height: 18)
        frequencySlider.target = self
        frequencySlider.action = #selector(frequencyChanged(_:))
        frequencySlider.isContinuous = true
        container.addSubview(frequencyCaption)
        container.addSubview(frequencySlider)
        item.view = container
        return item
    }

    private func updateFrequencyCaption() {
        frequencyCaption.stringValue = "Glitch frequency · \(AppSettings.frequencyCaption(AppSettings.frequency))"
    }

    @objc private func frequencyChanged(_ sender: NSSlider) {
        AppSettings.frequency = sender.doubleValue
        updateFrequencyCaption()
        session?.rescheduleIfIdle()
    }

    @objc private func triggerGlitch() {
        session?.trigger()
    }

    @objc private func testSensitivity() {
        session?.openSensitivityTest()
    }

    @objc private func admitDefeat() {
        session?.admitDefeat()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private enum StatusIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let chassis = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 1.5, yRadius: 1.5)
            chassis.lineWidth = 1.4
            NSColor.black.setStroke()
            chassis.stroke()

            let crack = NSBezierPath()
            crack.move(to: NSPoint(x: 6, y: 12))
            crack.line(to: NSPoint(x: 9, y: 8.5))
            crack.line(to: NSPoint(x: 8, y: 7.5))
            crack.line(to: NSPoint(x: 12.5, y: 5))
            crack.lineWidth = 1.1
            crack.stroke()

            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 7, y: 3.5))
            stand.line(to: NSPoint(x: 5.5, y: 1.8))
            stand.move(to: NSPoint(x: 11, y: 3.5))
            stand.line(to: NSPoint(x: 12.5, y: 1.8))
            stand.lineWidth = 1.2
            stand.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
