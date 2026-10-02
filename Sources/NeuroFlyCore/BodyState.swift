import Foundation

/// A small game body regulator for food motivation.
///
/// This is an engineered game mechanic layered around the neural simulation.
/// It is not a complete biological model of hunger, metabolism, or feeding.
public struct BodyState: Codable, Equatable, Sendable {
    public static let motivationOffThreshold = 0.20
    public static let motivationOnThreshold = 0.60

    public private(set) var hunger: Double
    public private(set) var isFoodMotivated: Bool
    public private(set) var consumedFood: Double

    public var foodDrive: Float { isFoodMotivated ? 1 : 0 }

    public init(hunger: Double = 0.65) {
        let safeHunger = Self.clampFinite(hunger, lower: 0, upper: 1, fallback: 0.65)
        self.hunger = safeHunger
        self.isFoodMotivated = safeHunger > Self.motivationOffThreshold
        self.consumedFood = 0
    }

    /// Advances the game body state by one simulation step.
    ///
    /// `foodConsumed` is the amount eaten during this frame, so it is not
    /// multiplied by `seconds`. Invalid or negative speed and intake values
    /// are ignored conservatively. A non-positive or non-finite duration
    /// leaves the state unchanged.
    public mutating func advance(seconds: Double, speed: Double, foodConsumed: Double) {
        guard seconds.isFinite, seconds > 0 else { return }

        let safeSpeed = speed.isFinite ? max(0, speed) : 0
        let speedRatio = min(1, safeSpeed / 120)
        let metabolicRate = 0.002 + 0.0005 * speedRatio
        let metabolicIncrease = min(1, metabolicRate * seconds)
        hunger = min(1, hunger + metabolicIncrease)

        let safeFood = foodConsumed.isFinite ? max(0, foodConsumed) : 0
        if safeFood > 0 {
            let reduction = safeFood > hunger / 1.2 ? hunger : safeFood * 1.2
            hunger = max(0, hunger - reduction)

            let accumulated = consumedFood + safeFood
            consumedFood = accumulated.isFinite ? accumulated : .greatestFiniteMagnitude
        }

        if hunger <= Self.motivationOffThreshold {
            isFoodMotivated = false
        } else if hunger >= Self.motivationOnThreshold {
            isFoodMotivated = true
        }
    }

    private static func clampFinite(_ value: Double, lower: Double, upper: Double,
                                    fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(upper, max(lower, value))
    }
}
