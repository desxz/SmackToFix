import AppKit
import SwiftUI

@MainActor
final class SensitivityModel: ObservableObject {
    @Published var peak: Float = 0
    @Published var lowRatio: Float = 0
    @Published var threshold: Float = AppSettings.threshold
    @Published var slapped = false
    @Published var microphoneDenied = false
    @Published var inputProblem: String?
    @Published var heardPackets = 0
    var onThreshold: ((Float) -> Void)?
    private var flashTask: Task<Void, Never>?

    func apply(level: ImpactLevel) {
        heardPackets += 1
        peak = max(level.peak, peak * 0.82)
        lowRatio = level.lowRatio
    }

    func noteThreshold(_ value: Float) {
        let clamped = min(0.45, max(0.04, value))
        threshold = clamped
        onThreshold?(clamped)
    }

    func flash() {
        slapped = true
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            slapped = false
        }
    }
}

@MainActor
final class SensitivityTestPanel: NSPanel {
    init(model: SensitivityModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Slap Sensitivity"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: SensitivityTestView(model: model))
        center()
    }
}

private struct SensitivityTestView: View {
    @ObservedObject var model: SensitivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Smack the aluminum. The bar should clear the red line. Typing should not.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(model.slapped ? Color.green : Color.primary)
                        .frame(width: max(0, geo.size.width * CGFloat(min(model.peak / 0.3, 1))))
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 22)
                        .offset(x: geo.size.width * CGFloat(model.threshold) - 1)
                }
            }
            .frame(height: 22)
            Slider(
                value: Binding(
                    get: { Double(model.threshold) },
                    set: { model.noteThreshold(Float($0)) }
                ),
                in: 0.04...0.45
            )
            Text(statusLine)
                .font(.headline)
            Text(String(format: "Peak %.3f    low-band %.2f", model.peak, model.lowRatio))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 400)
    }

    private var statusLine: String {
        if model.microphoneDenied {
            return "Microphone is off. The chassis is safe from judgment."
        }
        if let inputProblem = model.inputProblem {
            return inputProblem
        }
        if model.heardPackets == 0 {
            return "Waiting for the microphone…"
        }
        return model.slapped ? "Slap." : "Hearing you."
    }
}
