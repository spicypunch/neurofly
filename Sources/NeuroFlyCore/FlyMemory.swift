import Foundation

/// The result observed by the associative-memory layer after a world step.
/// Food values are actual amounts consumed during that step, not taste or
/// proximity. Threat is a normalized sensory event intensity for that step.
public struct MemoryOutcome: Codable, Equatable, Sendable {
    public var bananaConsumed: Double
    public var berryConsumed: Double
    public var threat: Double

    public init(bananaConsumed: Double = 0, berryConsumed: Double = 0,
                threat: Double = 0) {
        self.bananaConsumed = bananaConsumed
        self.berryConsumed = berryConsumed
        self.threat = threat
    }

    public subscript(kind: FoodKind) -> Double {
        get {
            switch kind {
            case .banana: return bananaConsumed
            case .berry: return berryConsumed
            }
        }
        set {
            switch kind {
            case .banana: bananaConsumed = newValue
            case .berry: berryConsumed = newValue
            }
        }
    }
}

/// Public values suitable for a status panel or an experiment report.
/// `learnedFood` counts reward episodes, while `rewardedIntake` sums actual
/// consumed amounts. A continuous feeding stream therefore counts as one
/// learned food episode instead of one meal per rendered frame.
public struct FlyMemoryStats: Codable, Equatable, Sendable {
    public var bananaValue: Double
    public var berryValue: Double
    public var bananaGain: Float
    public var berryGain: Float
    public var learnedFood: Int
    public var rewardedIntake: Double
    public var threatAssociations: Int

    public init(bananaValue: Double = 0, berryValue: Double = 0,
                bananaGain: Float = 1, berryGain: Float = 1,
                learnedFood: Int = 0, rewardedIntake: Double = 0,
                threatAssociations: Int = 0) {
        self.bananaValue = bananaValue
        self.berryValue = berryValue
        self.bananaGain = bananaGain
        self.berryGain = berryGain
        self.learnedFood = learnedFood
        self.rewardedIntake = rewardedIntake
        self.threatAssociations = threatAssociations
    }
}

/// A small engineered association layer around the fixed connectome.
///
/// It learns only from coordinate-free food cues and post-step outcomes. The
/// current brain graph remains fixed: learned gains are applied to the raw
/// left/right odor drive before that drive enters the existing DM1 receptor
/// channel. This is a game-memory model, not synaptic plasticity or a claim
/// that the shipped FlyWire graph distinguishes banana from berry biologically.
public struct FlyMemory: Codable, Equatable, Sendable {
    public static let eligibilityTimeConstant: Double = 3
    public static let forgettingTimeConstant: Double = 600
    public static let learningRate: Double = 0.08
    /// Associations below five percent of the maximum trace are treated as
    /// noise rather than counted as a learned episode. The trace is still
    /// retained for the value update: a short cue immediately before a
    /// reward/threat must be able to influence that outcome.
    public static let minimumAssociationTrace: Double = eligibilityTimeConstant * 0.05
    public static let minimumGain: Float = 0.15
    public static let maximumGain: Float = 2

    public var learningEnabled: Bool {
        didSet {
            if !learningEnabled { clearEphemeralState() }
        }
    }

    private var bananaValue: Double
    private var berryValue: Double
    private var bananaEligibility: Double
    private var berryEligibility: Double
    private var bananaRewardedIntake: Double
    private var berryRewardedIntake: Double
    private var learnedFoodEpisodes: Int
    private var threatAssociationCount: Int
    private var bananaRewardEpisodeOpen: Bool
    private var berryRewardEpisodeOpen: Bool
    private var threatEpisodeOpen: Bool

    public init(learningEnabled: Bool = true) {
        self.learningEnabled = learningEnabled
        bananaValue = 0
        berryValue = 0
        bananaEligibility = 0
        berryEligibility = 0
        bananaRewardedIntake = 0
        berryRewardedIntake = 0
        learnedFoodEpisodes = 0
        threatAssociationCount = 0
        bananaRewardEpisodeOpen = false
        berryRewardEpisodeOpen = false
        threatEpisodeOpen = false
    }

    /// Returns exactly 1 for an untrained memory and for a disabled memory.
    public func gain(for kind: FoodKind) -> Float {
        guard learningEnabled else { return 1 }
        return Self.gain(from: value(for: kind))
    }

    public func value(for kind: FoodKind) -> Double {
        switch kind {
        case .banana: return bananaValue
        case .berry: return berryValue
        }
    }

    public var stats: FlyMemoryStats {
        FlyMemoryStats(
            bananaValue: bananaValue,
            berryValue: berryValue,
            bananaGain: gain(for: .banana),
            berryGain: gain(for: .berry),
            learnedFood: learnedFoodEpisodes,
            rewardedIntake: bananaRewardedIntake + berryRewardedIntake,
            threatAssociations: threatAssociationCount)
    }

    /// Applies only learned virtual-food weights to odorLeft/odorRight.
    /// Taste, looming, and touch are returned bit-for-bit unchanged.
    public func weightedSensoryInput(raw: SensoryInput,
                                     cues: FoodCueObservation) -> SensoryInput {
        guard learningEnabled,
              bananaValue != 0 || berryValue != 0 else { return raw }

        let bananaGain = Double(gain(for: .banana))
        let berryGain = Double(gain(for: .berry))
        let categorizedLeft = min(1, max(0, Double(cues.banana.left) + Double(cues.berry.left)))
        let categorizedRight = min(1, max(0, Double(cues.banana.right) + Double(cues.berry.right)))
        let residualLeft = max(0, Double(raw.odorLeft) - categorizedLeft)
        let residualRight = max(0, Double(raw.odorRight) - categorizedRight)
        let left = residualLeft +
            Double(cues.banana.left) * bananaGain +
            Double(cues.berry.left) * berryGain
        let right = residualRight +
            Double(cues.banana.right) * bananaGain +
            Double(cues.berry.right) * berryGain

        var result = raw
        result.odorLeft = Self.clampUnitFloat(left)
        result.odorRight = Self.clampUnitFloat(right)
        return result
    }

    /// Advances eligibility, forgetting, and outcome-based association.
    /// `bananaConsumed` and `berryConsumed` are actual post-contact intake;
    /// taste by itself cannot create a positive food association.
    public mutating func advance(seconds: Double,
                                 cues: FoodCueObservation,
                                 outcome: MemoryOutcome) {
        guard seconds.isFinite, seconds > 0 else { return }

        let safeCues = Self.sanitize(cues)
        let safeOutcome = Self.sanitize(outcome)

        if learningEnabled {
            // A threat is an intensity over the whole simulation step. The
            // helper integrates the bounded eligibility trace over that
            // interval instead of multiplying the end-of-step value by
            // `seconds`; the latter makes otherwise identical 30 Hz and 60 Hz
            // experiences learn slightly different values.
            let bananaTrace = Self.advanceTrace(previous: bananaEligibility,
                                                 cue: Double(safeCues.banana.total),
                                                 seconds: seconds)
            let berryTrace = Self.advanceTrace(previous: berryEligibility,
                                               cue: Double(safeCues.berry.total),
                                               seconds: seconds)
            bananaEligibility = bananaTrace.value
            berryEligibility = berryTrace.value

            let forgetting = exp(-seconds / Self.forgettingTimeConstant)
            // Food amounts are already per-step quantities and are not scaled.
            // Unlike food intake, threat is an intensity, so use the exact
            // interval integral calculated above.
            bananaValue = Self.clampValue(bananaValue * forgetting +
                Self.learningRate * safeOutcome.bananaConsumed * bananaEligibility -
                Self.learningRate * safeOutcome.threat * bananaTrace.integral)
            berryValue = Self.clampValue(berryValue * forgetting +
                Self.learningRate * safeOutcome.berryConsumed * berryEligibility -
                Self.learningRate * safeOutcome.threat * berryTrace.integral)
        } else {
            clearEphemeralState()
        }

        recordObservedOutcome(safeOutcome)
    }

    /// Clears learned values, counters, and eligibility while preserving the
    /// caller's learning-enabled setting.
    public mutating func reset() {
        bananaValue = 0
        berryValue = 0
        bananaRewardedIntake = 0
        berryRewardedIntake = 0
        learnedFoodEpisodes = 0
        threatAssociationCount = 0
        clearEphemeralState()
    }

    /// Explicitly clears transient traces before handing a copy to a store.
    /// The Codable implementation also omits traces, so a decoded checkpoint
    /// always resumes without a stale eligibility bridge.
    public var memoryForPersistence: FlyMemory {
        var copy = self
        copy.clearEphemeralState()
        return copy
    }

    public func preparedForResume() -> FlyMemory { memoryForPersistence }

    private mutating func recordObservedOutcome(_ outcome: MemoryOutcome) {
        bananaRewardedIntake = Self.saturatingAdd(bananaRewardedIntake, outcome.bananaConsumed)
        berryRewardedIntake = Self.saturatingAdd(berryRewardedIntake, outcome.berryConsumed)

        let bananaConsumed = outcome.bananaConsumed > 0
        let berryConsumed = outcome.berryConsumed > 0
        if learningEnabled {
            let bananaTraceQualifies = bananaEligibility >= Self.minimumAssociationTrace
            let berryTraceQualifies = berryEligibility >= Self.minimumAssociationTrace
            if bananaConsumed && !bananaRewardEpisodeOpen && bananaTraceQualifies {
                learnedFoodEpisodes = learnedFoodEpisodes < Int.max ? learnedFoodEpisodes + 1 : Int.max
            }
            if berryConsumed && !berryRewardEpisodeOpen && berryTraceQualifies {
                learnedFoodEpisodes = learnedFoodEpisodes < Int.max ? learnedFoodEpisodes + 1 : Int.max
            }

            let threatActive = outcome.threat > 0 &&
                max(bananaEligibility, berryEligibility) >= Self.minimumAssociationTrace
            if threatActive && !threatEpisodeOpen {
                threatAssociationCount = threatAssociationCount < Int.max
                    ? threatAssociationCount + 1 : Int.max
            }
            // Keep an episode open while its qualifying trace is still being
            // established. Closing it merely because the first few frames
            // were below threshold would prevent a continuous event from ever
            // being counted.
            threatEpisodeOpen = outcome.threat > 0 &&
                (threatEpisodeOpen || max(bananaEligibility, berryEligibility) >=
                    Self.minimumAssociationTrace)
        } else {
            threatEpisodeOpen = false
        }
        // The same delayed qualification rule applies to reward episodes.
        // An intake stream that starts before the odor trace crosses the
        // threshold must still count once it becomes eligible.
        bananaRewardEpisodeOpen = bananaConsumed &&
            (bananaRewardEpisodeOpen || bananaEligibility >= Self.minimumAssociationTrace)
        berryRewardEpisodeOpen = berryConsumed &&
            (berryRewardEpisodeOpen || berryEligibility >= Self.minimumAssociationTrace)
    }

    private mutating func clearEphemeralState() {
        bananaEligibility = 0
        berryEligibility = 0
        bananaRewardEpisodeOpen = false
        berryRewardEpisodeOpen = false
        threatEpisodeOpen = false
    }

    private static func sanitize(_ cues: FoodCueObservation) -> FoodCueObservation {
        FoodCueObservation(
            banana: BilateralFoodCue(left: clampUnitFloat(cues.banana.left),
                                     right: clampUnitFloat(cues.banana.right)),
            berry: BilateralFoodCue(left: clampUnitFloat(cues.berry.left),
                                    right: clampUnitFloat(cues.berry.right)),
            threat: clampUnitFloat(cues.threat))
    }

    private static func sanitize(_ outcome: MemoryOutcome) -> MemoryOutcome {
        MemoryOutcome(bananaConsumed: clampNonNegative(outcome.bananaConsumed),
                      berryConsumed: clampNonNegative(outcome.berryConsumed),
                      threat: clampUnitDouble(outcome.threat))
    }

    private static func gain(from value: Double) -> Float {
        let exponent = min(log(Double(maximumGain)), max(log(Double(minimumGain)), value))
        return Float(min(Double(maximumGain), max(Double(minimumGain), exp(exponent))))
    }

    private static func clampValue(_ value: Double) -> Double {
        guard value.isFinite else { return value.sign == .minus ? -8 : 8 }
        return min(8, max(-8, value))
    }

    private static func clampTrace(_ value: Double) -> Double {
        guard value.isFinite else { return value.sign == .minus ? 0 : eligibilityTimeConstant }
        return min(eligibilityTimeConstant, max(0, value))
    }

    /// Advances the first-order eligibility trace and returns its exact
    /// time-integral for a constant cue during the step. The trace is bounded
    /// at `eligibilityTimeConstant`, so the integral is split at the instant
    /// where an above-cap steady state reaches that bound.
    private static func advanceTrace(previous: Double,
                                     cue: Double,
                                     seconds: Double) -> (value: Double, integral: Double) {
        let tau = eligibilityTimeConstant
        let duration = max(0, seconds)
        let old = clampTrace(previous)
        let safeCue = max(0, cue.isFinite ? cue : 0)
        let steadyState = safeCue * tau

        func unboundedValue(at time: Double) -> Double {
            steadyState + (old - steadyState) * exp(-time / tau)
        }

        func unboundedIntegral(for time: Double) -> Double {
            let decayIntegral = tau * (1 - exp(-time / tau))
            return old * decayIntegral + steadyState * (time - decayIntegral)
        }

        guard duration > 0 else { return (old, 0) }

        // With a steady state at or below the cap, the trace never clips on
        // the way toward it. A prior value at the cap decays normally unless
        // the cue keeps it pinned at the cap.
        guard steadyState > tau else {
            let value = clampTrace(unboundedValue(at: duration))
            return (value, max(0, unboundedIntegral(for: duration)))
        }

        // Once an above-cap steady state has already reached the cap, the
        // bounded trace remains there for the whole step.
        if old >= tau { return (tau, tau * duration) }

        let crossingRatio = (steadyState - tau) / (steadyState - old)
        let crossingTime = -tau * log(crossingRatio)
        guard crossingTime.isFinite, crossingTime > 0, crossingTime < duration else {
            let value = clampTrace(unboundedValue(at: duration))
            return (value, max(0, unboundedIntegral(for: duration)))
        }

        let integralBeforeCap = unboundedIntegral(for: crossingTime)
        let integralAfterCap = tau * (duration - crossingTime)
        return (tau, max(0, integralBeforeCap + integralAfterCap))
    }

    private static func clampNonNegative(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func clampUnitDouble(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func clampUnitFloat(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func clampUnitFloat(_ value: Double) -> Float {
        guard value.isFinite else { return 0 }
        return Float(min(1, max(0, value)))
    }

    private static func saturatingAdd(_ lhs: Double, _ rhs: Double) -> Double {
        let result = lhs + rhs
        return result.isFinite ? result : .greatestFiniteMagnitude
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, learningEnabled, bananaValue, berryValue
        case bananaRewardedIntake, berryRewardedIntake
        case learnedFoodEpisodes, threatAssociationCount
        case bananaRewardEpisodeOpen, berryRewardEpisodeOpen, threatEpisodeOpen
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(learningEnabled, forKey: .learningEnabled)
        try container.encode(bananaValue, forKey: .bananaValue)
        try container.encode(berryValue, forKey: .berryValue)
        try container.encode(bananaRewardedIntake, forKey: .bananaRewardedIntake)
        try container.encode(berryRewardedIntake, forKey: .berryRewardedIntake)
        try container.encode(learnedFoodEpisodes, forKey: .learnedFoodEpisodes)
        try container.encode(threatAssociationCount, forKey: .threatAssociationCount)
        try container.encode(bananaRewardEpisodeOpen, forKey: .bananaRewardEpisodeOpen)
        try container.encode(berryRewardEpisodeOpen, forKey: .berryRewardEpisodeOpen)
        try container.encode(threatEpisodeOpen, forKey: .threatEpisodeOpen)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported FlyMemory schema version \(schemaVersion)")
        }
        learningEnabled = try container.decodeIfPresent(Bool.self, forKey: .learningEnabled) ?? true
        bananaValue = Self.clampValue(try container.decodeIfPresent(Double.self, forKey: .bananaValue) ?? 0)
        berryValue = Self.clampValue(try container.decodeIfPresent(Double.self, forKey: .berryValue) ?? 0)
        bananaEligibility = 0
        berryEligibility = 0
        bananaRewardedIntake = Self.clampNonNegative(
            try container.decodeIfPresent(Double.self, forKey: .bananaRewardedIntake) ?? 0)
        berryRewardedIntake = Self.clampNonNegative(
            try container.decodeIfPresent(Double.self, forKey: .berryRewardedIntake) ?? 0)
        learnedFoodEpisodes = max(0, try container.decodeIfPresent(Int.self, forKey: .learnedFoodEpisodes) ?? 0)
        threatAssociationCount = max(0, try container.decodeIfPresent(Int.self, forKey: .threatAssociationCount) ?? 0)
        bananaRewardEpisodeOpen = try container.decodeIfPresent(Bool.self, forKey: .bananaRewardEpisodeOpen) ?? false
        berryRewardEpisodeOpen = try container.decodeIfPresent(Bool.self, forKey: .berryRewardEpisodeOpen) ?? false
        threatEpisodeOpen = try container.decodeIfPresent(Bool.self, forKey: .threatEpisodeOpen) ?? false
        if !learningEnabled { clearEphemeralState() }
    }

}
