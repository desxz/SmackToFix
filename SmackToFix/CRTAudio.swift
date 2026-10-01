import AVFoundation
import Foundation

/// Procedural CRT hum and the shutdown pop. Nothing is read from disk.
final class CRTAudio {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()

    init(engine: AVAudioEngine) {
        self.engine = engine
    }
    private var buzzBuffer: AVAudioPCMBuffer?
    private var popBuffer: AVAudioPCMBuffer?
    private var attached = false

    func startBuzz() {
        guard engine.isRunning, let buzzBuffer else { return }
        player.stop()
        player.scheduleBuffer(buzzBuffer, at: nil, options: .loops)
        player.play()
    }

    /// Cuts the hum and plays the snap. The output engine stops after the pop finishes.
    func playPopAndStopBuzz() {
        guard engine.isRunning, let popBuffer else {
            stop()
            return
        }
        player.stop()
        player.scheduleBuffer(popBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stop()
            }
        }
        player.play()
    }

    /// Stops the hum or pop. The shared engine keeps running so the microphone tap stays alive.
    func stop() {
        if player.isPlaying {
            player.stop()
        }
    }

    /// Call only while the engine is stopped, after it has been started once.
    /// The mixer rate is what the player has to match. The hardware output rate
    /// is often 48000 while the mixer is 44100, and that mismatch leaves the
    /// player disconnected.
    @discardableResult
    func attach() -> Bool {
        if attached { return true }
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        guard mixer.sampleRate > 0, mixer.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: mixer.sampleRate, channels: mixer.channelCount)
        else { return false }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        buzzBuffer = Self.makeBuzz(format: format)
        popBuffer = Self.makePop(format: format)
        attached = buzzBuffer != nil && popBuffer != nil
        return attached
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
            // A 60 Hz hum at a few percent does not come out of a laptop speaker.
            // The crackle has to live where the speaker actually plays.
            let hum = sin(2 * Double.pi * 240 * t) * 0.22 + sin(2 * Double.pi * 480 * t) * 0.12
            let crackle = abs(white) > 0.55 ? white * 0.72 : white * 0.16
            let sample = Float(hum) * 0.35 + crackle * 0.28
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
