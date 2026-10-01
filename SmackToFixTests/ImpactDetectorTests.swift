import XCTest

final class ImpactDetectorTests: XCTestCase {
    func testBassImpulseRegistersOneSlap() {
        var classifier = ImpactClassifier()
        let hits = classifier.ingest(samples: SignalFixtures.bassThump(sampleRate: 48_000), sampleRate: 48_000, startingAt: 0)
        XCTAssertEqual(hits, 1)
    }

    func testBrightChassisTapRegisters() {
        var classifier = ImpactClassifier()
        let hits = classifier.ingest(samples: SignalFixtures.brightTap(sampleRate: 48_000), sampleRate: 48_000, startingAt: 0)
        XCTAssertEqual(hits, 1)
    }

    func testQuietClickIsIgnored() {
        var classifier = ImpactClassifier()
        let quiet = SignalFixtures.bassThump(sampleRate: 48_000).map { $0 * 0.05 }
        let hits = classifier.ingest(samples: quiet, sampleRate: 48_000, startingAt: 0)
        XCTAssertEqual(hits, 0)
    }

    func testSustainedToneIsIgnored() {
        var classifier = ImpactClassifier()
        let hits = classifier.ingest(samples: SignalFixtures.longTone(sampleRate: 48_000), sampleRate: 48_000, startingAt: 0)
        XCTAssertEqual(hits, 0)
    }

    func testSecondHitInsideDebounceIsIgnored() {
        var classifier = ImpactClassifier()
        let sampleRate = 48_000.0
        let thump = SignalFixtures.bassThump(sampleRate: sampleRate)
        let shortGap = [Float](repeating: 0, count: Int(sampleRate * 0.11))
        let recoveryGap = [Float](repeating: 0, count: Int(sampleRate * 0.80))
        let samples = thump + shortGap + thump + recoveryGap + thump
        let hits = classifier.ingest(samples: samples, sampleRate: sampleRate, startingAt: 0)
        XCTAssertEqual(hits, 2)
    }
}

private enum SignalFixtures {
    static func bassThump(sampleRate: Double) -> [Float] {
        let count = Int(sampleRate * 0.09)
        var samples = [Float](repeating: 0, count: count)
        let bodyCount = Int(sampleRate * 0.014)
        let spike = 0.35
        for index in 0..<bodyCount {
            let t = Double(index) / sampleRate
            let envelope = exp(-t / 0.0015)
            let body = sin(2 * Double.pi * 120 * t)
            let mixed = (1 - spike) * (0.5 + 0.5 * body) + (index < 8 ? spike : 0)
            samples[index] = Float(0.9 * envelope * mixed)
        }
        for index in 0..<6 {
            samples[index] = min(1, samples[index] + Float(0.55 * (1 - Double(index) / 6)))
        }
        return samples
    }

    /// A side-of-the-Mac tick: loud, short, and mostly high frequency.
    static func brightTap(sampleRate: Double) -> [Float] {
        let count = Int(sampleRate * 0.09)
        var samples = [Float](repeating: 0, count: count)
        samples[0] = 0.72
        samples[1] = -0.28
        samples[2] = 0.12
        return samples
    }

    static func longTone(sampleRate: Double) -> [Float] {
        let count = Int(sampleRate * 0.40)
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            return Float(0.8 * sin(2 * Double.pi * 180 * t))
        }
    }
}
