import AVFoundation
import Foundation

struct ImpactHop: Equatable, CustomStringConvertible {
    var peak: Float
    var rms: Float
    var lowRatio: Float

    var crest: Float {
        peak / max(rms, 0.00001)
    }

    var description: String {
        String(format: "peak %.3f rms %.3f crest %.2f low %.2f", peak, rms, crest, lowRatio)
    }
}

enum ImpactAnalysis {
    /// One-pole lowpass near 300 Hz, then peak, RMS, and low-band energy share per hop.
    static func hops(samples: [Float], sampleRate: Double, hopDuration: Double = 0.010) -> [ImpactHop] {
        guard sampleRate > 0, hopDuration > 0, !samples.isEmpty else { return [] }
        let hopLength = max(1, Int((hopDuration * sampleRate).rounded()))
        let alpha = Float(1 - exp(-2 * Double.pi * 300 / sampleRate))
        var low: Float = 0
        var hops: [ImpactHop] = []
        hops.reserveCapacity(samples.count / hopLength + 1)
        var offset = 0
        while offset < samples.count {
            let count = min(hopLength, samples.count - offset)
            var peak: Float = 0
            var sumSquares: Float = 0
            var lowSquares: Float = 0
            for index in 0..<count {
                let sample = samples[offset + index]
                peak = max(peak, abs(sample))
                sumSquares += sample * sample
                low += alpha * (sample - low)
                lowSquares += low * low
            }
            let rms = sqrt(sumSquares / Float(count))
            let lowRMS = sqrt(lowSquares / Float(count))
            let ratio = min(lowRMS / max(rms, 0.000001), 4)
            hops.append(ImpactHop(peak: peak, rms: rms, lowRatio: ratio))
            offset += count
        }
        return hops
    }
}

struct ImpactClassifier {
    struct Configuration: Equatable {
        var threshold: Float = 0.06
        var minimumCrest: Float = 2.5
        var minimumLowRatio: Float = 0.22
        /// A bright chassis tick can skip the bass check once it is at least this loud.
        var loudBypass: Float = 0.12
        var minimumDuration: TimeInterval = 0.008
        var maximumDuration: TimeInterval = 0.180
        var debounce: TimeInterval = 0.700
        var releaseFactor: Float = 0.4
        var releaseHops: Int = 2
    }

    var configuration = Configuration()
    private(set) var latest = ImpactHop(peak: 0, rms: 0, lowRatio: 0)
    private var inEvent = false
    private var eventStart: TimeInterval = 0
    private var belowRelease = 0
    private var lastAccept: TimeInterval = -.infinity

    mutating func reset() {
        latest = ImpactHop(peak: 0, rms: 0, lowRatio: 0)
        inEvent = false
        eventStart = 0
        belowRelease = 0
        lastAccept = -.infinity
    }

    /// Feeds PCM and returns how many slaps closed inside this buffer.
    @discardableResult
    mutating func ingest(samples: [Float], sampleRate: Double, hopDuration: Double = 0.010, startingAt time: TimeInterval) -> Int {
        let measured = ImpactAnalysis.hops(samples: samples, sampleRate: sampleRate, hopDuration: hopDuration)
        var hits = 0
        var cursor = time
        for hop in measured {
            if consume(hop, hopDuration: hopDuration, at: cursor) {
                hits += 1
            }
            cursor += hopDuration
        }
        return hits
    }

    mutating func consume(_ hop: ImpactHop, hopDuration: TimeInterval, at time: TimeInterval) -> Bool {
        latest = hop
        let aboveFloor = hop.peak >= configuration.threshold
        let impulsive = hop.crest >= configuration.minimumCrest
        let sharpTick = aboveFloor && hop.crest >= 6
        let loudTick = hop.peak >= configuration.loudBypass && impulsive
        let bassThump = aboveFloor && impulsive && hop.lowRatio >= configuration.minimumLowRatio
        let armed = sharpTick || loudTick || bassThump
        let released = hop.peak < configuration.threshold * configuration.releaseFactor

        if !inEvent {
            if armed {
                inEvent = true
                eventStart = time
                belowRelease = 0
            }
            return false
        }

        let elapsed = time + hopDuration - eventStart
        if elapsed > configuration.maximumDuration {
            inEvent = false
            belowRelease = 0
            return false
        }

        if released {
            belowRelease += 1
            if belowRelease >= configuration.releaseHops {
                inEvent = false
                belowRelease = 0
                guard elapsed >= configuration.minimumDuration else { return false }
                guard time - lastAccept >= configuration.debounce else { return false }
                lastAccept = time
                return true
            }
        } else {
            belowRelease = 0
        }
        return false
    }
}

struct ImpactLevel: Equatable {
    var peak: Float
    var lowRatio: Float
}

final class ImpactDetector {
    var onImpact: (() -> Void)?
    var onLevel: ((ImpactLevel) -> Void)?

    var threshold: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return classifier.configuration.threshold
        }
        set {
            lock.lock()
            classifier.configuration.threshold = newValue
            lock.unlock()
        }
    }

    let engine = AVAudioEngine()
    /// Connects the buzz player while the engine is stopped, after one priming start.
    /// Returns whether the player is actually in the graph.
    var outputPrepare: (() -> Bool)?
    private let processingQueue = DispatchQueue(label: "com.smacktofix.impact")
    private let lock = NSLock()
    private var classifier = ImpactClassifier()
    private var sampleCursor: TimeInterval = 0
    private var tapInstalled = false
    private var running = false
    /// The player stays connected across later stop/start cycles.
    private var playbackConnected = false

    func start(resetHistory: Bool) throws {
        if running {
            if resetHistory {
                lock.lock()
                classifier.reset()
                sampleCursor = 0
                lock.unlock()
            }
            return
        }

        let input = engine.inputNode
        // Do not assign kAudioOutputUnitProperty_CurrentDevice here. On this Mac that
        // call zeroes the output hardware format (0 Hz, 0 ch) and engine.start()
        // then fails with -10875 or canPerformIO. The default input is already the
        // built-in microphone.

        var format = input.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            format = input.inputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ImpactDetectorError.noInputFormat
        }

        lock.lock()
        if resetHistory {
            classifier.reset()
            sampleCursor = 0
        }
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
        // The first start() is only there to make the mixer format real. Connecting
        // the player before that throws -10875. Connecting it while this start is
        // still running leaves the player disconnected, and play() then throws.
        // Stop, connect at the mixer rate (often 44100, not the 48000 hardware
        // rate), then start again. The tap stays installed across that stop.
        if !playbackConnected, let outputPrepare {
            engine.stop()
            if outputPrepare() {
                playbackConnected = true
            }
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                tapInstalled = false
                throw error
            }
        }
        running = true
    }

    func stop() {
        guard running || tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        running = false
        lock.lock()
        classifier.reset()
        sampleCursor = 0
        lock.unlock()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let samples = Self.loudestChannel(buffer, frames: frames) else { return }
        let sampleRate = buffer.format.sampleRate
        processingQueue.async { [weak self] in
            self?.classify(samples, sampleRate: sampleRate)
        }
    }

    /// MacBook input is sometimes stereo with the capsule on only one side. Channel 0 can be silence.
    private static func loudestChannel(_ buffer: AVAudioPCMBuffer, frames: Int) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = max(1, Int(buffer.format.channelCount))
        var best = 0
        var bestPeak: Float = -1
        for channel in 0..<channelCount {
            let samples = channels[channel]
            var peak: Float = 0
            for index in 0..<frames {
                peak = max(peak, abs(samples[index]))
            }
            if peak > bestPeak {
                bestPeak = peak
                best = channel
            }
        }
        return Array(UnsafeBufferPointer(start: channels[best], count: frames))
    }

    private func classify(_ samples: [Float], sampleRate: Double) {
        lock.lock()
        let start = sampleCursor
        let hits = classifier.ingest(samples: samples, sampleRate: sampleRate, startingAt: start)
        sampleCursor = start + Double(samples.count) / sampleRate
        let level = ImpactLevel(peak: classifier.latest.peak, lowRatio: classifier.latest.lowRatio)
        lock.unlock()

        if hits > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onImpact?()
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
        }
    }
}

enum ImpactDetectorError: Error {
    case noInputFormat
}
