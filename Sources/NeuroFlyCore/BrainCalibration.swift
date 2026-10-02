import Foundation

/// Calibration of an engineered 2D readout, not a learned biological motor circuit.
public struct BrainCalibration: Codable, Sendable {
    public struct OdorBalance: Codable, Sendable {
        public var totalHz: Double
        public var leftFraction: Double
    }
    public var baseline: NeuralReadout
    public var odorBalance: [OdorBalance]

    public init(baseline: NeuralReadout = NeuralReadout(), odorBalance: [OdorBalance] = []) {
        self.baseline = baseline; self.odorBalance = odorBalance
    }

    public func balancedLeftFraction(total: Double) -> Double {
        guard let first = odorBalance.first, let last = odorBalance.last else { return 0.5 }
        if total <= first.totalHz { return first.leftFraction }
        if total >= last.totalHz { return last.leftFraction }
        for (a, b) in zip(odorBalance, odorBalance.dropFirst()) where total <= b.totalHz {
            let weight = (total - a.totalHz) / max(0.001, b.totalHz - a.totalHz)
            return a.leftFraction + weight * (b.leftFraction - a.leftFraction)
        }
        return last.leftFraction
    }

    /// Each symmetric odor probe starts from the same state. It estimates the
    /// connectome's left/right response bias at several activation levels.
    /// No world state, object coordinates, or desired heading enters this pass.
    public static func measure(brain: BrainEngine, seed: UInt32 = 42) throws -> BrainCalibration {
        var calibration = BrainCalibration()
        try prepare(brain: brain, seed: seed)
        var base: [NeuralReadout] = []
        for _ in 0..<10 { base.append(try brain.advance(milliseconds: 50, input: SensoryInput())) }
        calibration.baseline = average(base)
        for concentration: Float in [0.05, 0.15, 0.35, 0.65, 1] {
            try prepare(brain: brain, seed: seed)
            var samples: [NeuralReadout] = []
            for step in 0..<20 {
                let response = try brain.advance(milliseconds: 50,
                    input: SensoryInput(odorLeft: concentration, odorRight: concentration))
                if step >= 10 { samples.append(response) }
            }
            let mean = average(samples)
            let total = Double(mean.odorRelayLeftHz + mean.odorRelayRightHz)
            if total > 1 {
                calibration.odorBalance.append(OdorBalance(totalHz: total,
                    leftFraction: Double(mean.odorRelayLeftHz) / total))
            }
        }
        calibration.odorBalance.sort { $0.totalHz < $1.totalHz }
        try prepare(brain: brain, seed: seed)
        return calibration
    }

    public static func prepare(brain: BrainEngine, seed: UInt32 = 42) throws {
        try brain.reset(seed: seed)
        for _ in 0..<10 { _ = try brain.advance(milliseconds: 50, input: SensoryInput()) }
    }

    private static func average(_ samples: [NeuralReadout]) -> NeuralReadout {
        func mean(_ key: KeyPath<NeuralReadout, Float>) -> Float {
            samples.reduce(0) { $0 + $1[keyPath: key] } / Float(max(1, samples.count))
        }
        return NeuralReadout(turnLeftHz: mean(\.turnLeftHz), turnRightHz: mean(\.turnRightHz),
            forwardHz: mean(\.forwardHz), escapeHz: mean(\.escapeHz), feedingHz: mean(\.feedingHz),
            groomingHz: mean(\.groomingHz), odorRelayLeftHz: mean(\.odorRelayLeftHz),
            odorRelayRightHz: mean(\.odorRelayRightHz), populationHz: mean(\.populationHz))
    }
}
