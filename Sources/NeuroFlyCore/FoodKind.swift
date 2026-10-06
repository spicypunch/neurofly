import Foundation

/// Virtual food identities used by the engineered associative-memory layer.
/// They are not claims that the current DM1-only graph contains two verified
/// odor-specific pathways.
public enum FoodKind: String, Codable, CaseIterable, Hashable, Sendable {
    case banana
    case berry

    public var displayName: String {
        switch self {
        case .banana: return "바나나"
        case .berry: return "베리"
        }
    }
}

/// A bilateral, coordinate-free virtual odor cue for one food identity.
public struct BilateralFoodCue: Codable, Equatable, Sendable {
    public var left: Float
    public var right: Float

    public init(left: Float = 0, right: Float = 0) {
        self.left = left
        self.right = right
    }

    public var total: Float { left + right }
}

/// Food identity cues are kept outside the six raw receptor channels. The
/// memory layer may use them to weight the existing left/right odor drive;
/// coordinates and target bearings never cross this boundary.
public struct FoodCueObservation: Codable, Equatable, Sendable {
    public var banana: BilateralFoodCue
    public var berry: BilateralFoodCue
    public var threat: Float

    public init(banana: BilateralFoodCue = BilateralFoodCue(),
                berry: BilateralFoodCue = BilateralFoodCue(),
                threat: Float = 0) {
        self.banana = banana
        self.berry = berry
        self.threat = threat
    }

    public subscript(kind: FoodKind) -> BilateralFoodCue {
        get {
            switch kind {
            case .banana: return banana
            case .berry: return berry
            }
        }
        set {
            switch kind {
            case .banana: banana = newValue
            case .berry: berry = newValue
            }
        }
    }
}
