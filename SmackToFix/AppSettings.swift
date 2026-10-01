import Foundation

enum AppSettings {
    private static let frequencyKey = "glitchFrequency"
    private static let thresholdKey = "slapThreshold.v2"

    /// 0 is rare (about 45–90 minutes). 0.5 is the default (about 4–8 minutes). 1 is demo mode (about 20–45 seconds).
    static var frequency: Double {
        get {
            if UserDefaults.standard.object(forKey: frequencyKey) == nil {
                return 0.5
            }
            return min(1, max(0, UserDefaults.standard.double(forKey: frequencyKey)))
        }
        set {
            UserDefaults.standard.set(min(1, max(0, newValue)), forKey: frequencyKey)
        }
    }

    /// Linear peak amplitude. The sensitivity panel clamps this to 0.04...0.45.
    static var threshold: Float {
        get {
            if UserDefaults.standard.object(forKey: thresholdKey) == nil {
                return 0.06
            }
            let stored = UserDefaults.standard.float(forKey: thresholdKey)
            return min(0.45, max(0.04, stored))
        }
        set {
            UserDefaults.standard.set(min(0.45, max(0.04, newValue)), forKey: thresholdKey)
        }
    }

    static func intervalRange(for frequency: Double) -> ClosedRange<TimeInterval> {
        let t = min(1, max(0, frequency))
        let minSeconds: Double
        let maxSeconds: Double
        if t <= 0.5 {
            let u = t / 0.5
            minSeconds = logLerp(45 * 60, 4 * 60, u)
            maxSeconds = logLerp(90 * 60, 8 * 60, u)
        } else {
            let u = (t - 0.5) / 0.5
            minSeconds = logLerp(4 * 60, 20, u)
            maxSeconds = logLerp(8 * 60, 45, u)
        }
        return minSeconds...maxSeconds
    }

    static func frequencyCaption(_ frequency: Double) -> String {
        let range = intervalRange(for: frequency)
        return "Every \(format(range.lowerBound))–\(format(range.upperBound))"
    }

    private static func logLerp(_ a: Double, _ b: Double, _ u: Double) -> Double {
        exp(log(a) + (log(b) - log(a)) * u)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        if seconds >= 90 {
            let minutes = Int((seconds / 60).rounded())
            return "\(minutes) min"
        }
        return "\(Int(seconds.rounded())) sec"
    }
}
