import Foundation

/// A perceptual display level, not an audio gain or a speech detector.
public struct AudioLevelMeter: Sendable {
    private var smoothedLevel = 0.0

    public init() {}

    public var level: Float { Float(smoothedLevel) }

    /// Timing comes from captured samples, never wall-clock or UI update speed.
    @discardableResult
    public mutating func update(rms: Double, frameCount: Int, sampleRate: Double) -> Float {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return level }

        let target: Double
        if rms.isFinite, rms > 0 {
            let decibels = 20 * log10(rms)
            target = min(1, max(0, (decibels + 68) / 50)) // -68...-18 dBFS.
        } else {
            target = 0
        }

        let duration = Double(frameCount) / sampleRate
        let timeConstant = target > smoothedLevel ? 0.020 : 0.130
        let response = -expm1(-duration / timeConstant)
        smoothedLevel += (target - smoothedLevel) * response

        // Below a fraction of a pixel, settle instead of retaining an endless
        // exponential tail. Quiet but nonzero signals are not rounded away.
        if target == 0, smoothedLevel < 0.02 { smoothedLevel = 0 }
        return level
    }
}
