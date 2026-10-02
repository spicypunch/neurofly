import Foundation

/// A measured bilateral odor response for one virtual input probe.
///
/// `contrast` is the known probe input contrast, where positive means that
/// the left receptor input was larger and negative means that the right input
/// was larger. `label` stores only that sign (`-1`, `0`, or `1`). It is a
/// calibration label for this engineered adapter, not a biological annotation.
public struct OdorResponse: Codable, Equatable, Sendable {
    public var meanConcentration: Double
    public var contrast: Double
    public var leftHz: Double
    public var rightHz: Double
    public var label: Int

    public init(meanConcentration: Double, contrast: Double,
                leftHz: Double, rightHz: Double, label: Int? = nil) {
        self.meanConcentration = meanConcentration
        self.contrast = contrast
        self.leftHz = leftHz
        self.rightHz = rightHz
        let inferred = contrast > 0 ? 1 : contrast < 0 ? -1 : 0
        self.label = label ?? inferred
    }
}
/// Calibration of an engineered 2D readout, not a learned biological motor circuit.
public struct BrainCalibration: Codable, Sendable {
    public struct OdorBalance: Codable, Sendable {
        public var totalHz: Double
        public var leftFraction: Double
    }

    public var baseline: NeuralReadout
    public var odorBalance: [OdorBalance]
    public var odorResponses: [OdorResponse]

    public init(baseline: NeuralReadout = NeuralReadout(),
                odorBalance: [OdorBalance] = [],
                odorResponses: [OdorResponse] = []) {
        self.baseline = baseline
        self.odorBalance = odorBalance
        self.odorResponses = odorResponses
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

    /// Estimate lateral odor direction from only the two measured DM1 relay
    /// rates. Positive means the calibrated response is more consistent with a
    /// stronger left input; negative means right. No world state or coordinates
    /// enter this lookup.
    public func estimateDirection(leftHz: Double, rightHz: Double) -> Double {
        guard !odorResponses.isEmpty,
              leftHz.isFinite, rightHz.isFinite else { return 0 }
        let left = max(0, leftHz)
        let right = max(0, rightHz)
        let total = left + right
        let fraction = total > 0 ? left / total : 0.5
        guard total.isFinite, fraction.isFinite else { return 0 }

        let totals = odorResponses.map { max(0, $0.leftHz) + max(0, $0.rightHz) }
        guard let minimum = totals.min(), let maximum = totals.max() else {
            return 0
        }
        let totalScale = max(1, maximum - minimum)
        let ratioScale = 15.0

        struct Candidate {
            let distance: Double
            let response: OdorResponse
        }
        let candidates = odorResponses.map { response -> Candidate in
            let responseTotal = max(0, response.leftHz) + max(0, response.rightHz)
            let responseFraction = responseTotal > 0 ? max(0, response.leftHz) / responseTotal : 0.5
            let totalDelta = (total - responseTotal) / totalScale
            let fractionDelta = (fraction - responseFraction) * ratioScale
            return Candidate(distance: hypot(totalDelta, fractionDelta), response: response)
        }
        let nearest = candidates.sorted { $0.distance < $1.distance }.prefix(min(4, candidates.count))
        guard let closest = nearest.first else { return 0 }
        if closest.distance <= 1e-9 {
            let label = max(-1, min(1, closest.response.label))
            return Double(label)
        }

        var weightedLabel = 0.0
        var totalWeight = 0.0
        for candidate in nearest {
            let weight = 1 / max(1e-6, candidate.distance * candidate.distance)
            weightedLabel += weight * Double(max(-1, min(1, candidate.response.label)))
            totalWeight += weight
        }
        let direction = max(-1, min(1, weightedLabel / max(1e-9, totalWeight)))
        return direction
    }

    /// Each symmetric odor probe starts from the same state. It estimates the
    /// connectome's left/right response bias at several activation levels.
    /// A second bilateral lookup uses known input contrasts to make the
    /// nonlinear two-PN readout inspectable without bypassing the graph.
    /// No world state, object coordinates, or desired heading enters this pass.
    public static func measure(brain: BrainEngine, seed: UInt32 = 42) throws -> BrainCalibration {
        var calibration = BrainCalibration()
        try prepare(brain: brain, seed: seed)
        var base: [NeuralReadout] = []
        for _ in 0..<10 { base.append(try brain.advance(milliseconds: 50, input: SensoryInput())) }
        calibration.baseline = average(base)

        // Keep the symmetric calibration curve for diagnostic comparison. The bilateral lookup below has a longer probe window so
        // its rates average the fixed-step noise over the final 1000 ms.
        for concentration: Float in [0.06, 0.10, 0.15, 0.25, 0.4, 0.65, 1] {
            let mean = try probe(brain: brain, seed: seed,
                                 input: SensoryInput(odorLeft: concentration,
                                                     odorRight: concentration),
                                 stimulusSteps: 20, tailSteps: 10)
            let total = Double(mean.odorRelayLeftHz + mean.odorRelayRightHz)
            if total > 1 {
                calibration.odorBalance.append(OdorBalance(totalHz: total,
                    leftFraction: Double(mean.odorRelayLeftHz) / total))
            }
        }
        calibration.odorBalance.sort { $0.totalHz < $1.totalHz }

        // Five common-mode levels × three known bilateral contrasts. The
        // labels are virtual input signs only; outputs remain real PN rates.
        for meanConcentration: Float in [0.08, 0.15, 0.3, 0.6, 0.9] {
            for inputContrast: Float in [-0.12, 0, 0.12] {
                let leftInput = min(1, max(0, meanConcentration * (1 + inputContrast)))
                let rightInput = min(1, max(0, meanConcentration * (1 - inputContrast)))
                let mean = try probe(brain: brain, seed: seed,
                                     input: SensoryInput(odorLeft: leftInput,
                                                         odorRight: rightInput),
                                     stimulusSteps: 30, tailSteps: 20)
                let label = inputContrast > 0 ? 1 : inputContrast < 0 ? -1 : 0
                calibration.odorResponses.append(OdorResponse(
                    meanConcentration: Double(meanConcentration),
                    contrast: Double(inputContrast),
                    leftHz: Double(mean.odorRelayLeftHz),
                    rightHz: Double(mean.odorRelayRightHz),
                    label: label))
            }
        }
        calibration.odorResponses.sort {
            if $0.meanConcentration != $1.meanConcentration {
                return $0.meanConcentration < $1.meanConcentration
            }
            return $0.contrast < $1.contrast
        }
        try prepare(brain: brain, seed: seed)
        return calibration
    }

    public static func prepare(brain: BrainEngine, seed: UInt32 = 42) throws {
        try brain.reset(seed: seed)
        for _ in 0..<10 { _ = try brain.advance(milliseconds: 50, input: SensoryInput()) }
    }

    private static func probe(brain: BrainEngine, seed: UInt32,
                              input: SensoryInput, stimulusSteps: Int,
                              tailSteps: Int) throws -> NeuralReadout {
        guard stimulusSteps > 0, tailSteps > 0, tailSteps <= stimulusSteps else {
            throw BrainEngineError.invalidArgument("invalid calibration probe window")
        }
        try prepare(brain: brain, seed: seed)
        var samples: [NeuralReadout] = []
        samples.reserveCapacity(tailSteps)
        for step in 0..<stimulusSteps {
            let response = try brain.advance(milliseconds: 50, input: input)
            if step >= stimulusSteps - tailSteps { samples.append(response) }
        }
        return average(samples)
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
