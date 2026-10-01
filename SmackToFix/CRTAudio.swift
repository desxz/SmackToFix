import AVFoundation
import Foundation

/// Procedural CRT hum and the shutdown pop. Nothing is read from disk.
final class CRTAudio {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()

    init(engine: AVAudioEngine) {
        self.engine = engine
    }
    private var format: AVAudioFormat?
    private var buzzBuffer: AVAudioPCMBuffer?
    private var popBuffer: AVAudioPCMBuffer?
    private var attached = false
    private var buzzing = false

    func startBuzz() {
        do {
            try prepareEngine()
            guard let buzzBuffer else { return }
            if !engine.isRunning {
                try engine.start()
            }
            player.stop()
            player.scheduleBuffer(buzzBuffer, at: nil, options: .loops)
            player.play()
            buzzing = true
        } catch {
            buzzing = false
        }
    }

    /// Cuts the hum and plays the snap. The output engine stops after the pop finishes.
    func playPopAndStopBuzz() {
        do {
            try prepareEngine()
            guard let popBuffer else { return }
            if !engine.isRunning {
                try engine.start()
            }
            player.stop()
            buzzing = false
            player.scheduleBuffer(popBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.stop()
                }
            }
            player.play()
        } catch {
            stop()
        }
    }

    /// Stops the hum or pop. The shared engine keeps running so the microphone tap stays alive.
    func stop() {
        if player.isPlaying {
            player.stop()
        }
        buzzing = false
    }

    func attach() {
        try? prepareEngine()
    }

    private func prepareEngine() throws {
        if !attached {
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            let sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 48_000
            let channels: AVAudioChannelCount = hardware.channelCount > 0 ? hardware.channelCount : 2
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.format = format
            buzzBuffer = Self.makeBuzz(format: format)
            popBuffer = Self.makePop(format: format)
            attached = true
        }
        _ = buzzing
    }

    private static func makeBuzz(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let left = buffer.floatChannelData?[0]
        let right = buffer.floatChannelData?[1]
        var noise = UInt32(0x12345678)
        for index in 0..<Int(frames) {
            let t = Double(index) / sampleRate
            noise = noise &* 1664525 &+ 1013904223
            let white = Float(Int32(bitPattern: noise)) / Float(Int32.max) 
            let hum = sin(2 * Double.pi * 60 * t) * 0.62 + sin(2 * Double.pi * 120 * t) * 0.28
            let sample = Float(hum) * 0.045 + white * 0.008
            left?[index] = sample
            right?[index] = sample
        }
        return buffer
    }

    private static func makePop(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * 0.28)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let left = buffer.floatChannelData?[0]
        let right = buffer.floatChannelData?[1]
        var noise = UInt32(0x51504F50)
        for index in 0..<Int(frames) {
            let t = Double(index) / sampleRate
            noise = noise &* 1664525 &+ 1013904223
            let white = Float(Int32(bitPattern: noise)) / Float(Int32.max)
            let crackle = white * Float(exp(-t / 0.018)) * 0.55
            let thump = Float(sin(2 * Double.pi * 90 * t) * exp(-t / 0.07)) * 0.85
            let sample = crackle + thump
            left?[index] = sample
            right?[index] = sample
        }
        return buffer
    }
}
