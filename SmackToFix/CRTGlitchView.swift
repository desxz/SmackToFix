import AppKit
import SwiftUI

enum CRTPhase {
    case glitching
    case collapsing
}

@MainActor
final class CRTGlitchModel: ObservableObject {
    @Published var frame: NSImage?
    @Published var showsFallback = true
    @Published var phase: CRTPhase = .glitching
    @Published var collapseX: CGFloat = 1
    @Published var collapseY: CGFloat = 1
    @Published var bloom: Double = 0
    @Published var opacity: Double = 1
    @Published var fallbackTime: TimeInterval = 0

    func resetForGlitch() {
        frame = nil
        showsFallback = true
        phase = .glitching
        collapseX = 1
        collapseY = 1
        bloom = 0
        opacity = 1
        fallbackTime = 0
    }
}

struct CRTGlitchView: View {
    @ObservedObject var model: CRTGlitchModel

    var body: some View {
        ZStack {
            if model.showsFallback || model.frame == nil {
                FallbackCRT(time: model.fallbackTime)
            }
            if let frame = model.frame {
                Image(nsImage: frame)
                    .resizable()
                    .interpolation(.none)
                    .opacity(model.showsFallback ? 0 : 1)
            }
            if model.phase == .collapsing {
                Rectangle()
                    .fill(Color.white)
                    .frame(height: 3)
                    .shadow(color: .white.opacity(0.9), radius: 10)
            }
        }
        .brightness(model.bloom)
        .scaleEffect(x: model.collapseX, y: model.collapseY, anchor: .center)
        .opacity(model.opacity)
        .animation(.easeIn(duration: 0.36), value: model.collapseY)
        .animation(.easeIn(duration: 0.16), value: model.collapseX)
        .animation(.easeOut(duration: 0.18), value: model.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

private struct FallbackCRT: View {
    var time: TimeInterval

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.24))
            )

            var y: CGFloat = 0
            while y < size.height {
                let line = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(line), with: .color(.black.opacity(0.28)))
                y += 3
            }

            let bandCount = 14
            let bandHeight = size.height / CGFloat(bandCount)
            for index in 0..<bandCount {
                let wobble = sin(time * 17 + Double(index) * 1.17)
                let tear = sin(time * 6 + Double(index) * 0.4) > 0.9
                let offset = CGFloat(wobble) * (tear ? 48 : 16)
                let bandY = CGFloat(index) * bandHeight
                let redBand = CGRect(x: offset, y: bandY, width: size.width, height: bandHeight)
                let cyanBand = CGRect(x: -offset * 0.65, y: bandY, width: size.width, height: bandHeight)
                context.fill(Path(redBand), with: .color(.red.opacity(tear ? 0.16 : 0.05)))
                context.fill(Path(cyanBand), with: .color(.cyan.opacity(tear ? 0.14 : 0.045)))
            }

            let roll = CGFloat((sin(time * 2.4) * 0.5 + 0.5)) * size.height
            let rollRect = CGRect(x: 0, y: roll, width: size.width, height: 18)
            context.fill(Path(rollRect), with: .color(.white.opacity(0.08)))
        }
    }
}
