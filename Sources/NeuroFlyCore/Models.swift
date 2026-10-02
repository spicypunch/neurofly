import Foundation

public struct Point2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public func distance(to other: Point2) -> Double { hypot(x - other.x, y - other.y) }
}

/// Virtual receptor signals. Only this value crosses from the world into the brain.
public struct SensoryInput: Codable, Equatable, Sendable {
    public var odorLeft: Float = 0
    public var odorRight: Float = 0
    public var taste: Float = 0
    public var loomingLeft: Float = 0
    public var loomingRight: Float = 0
    public var touch: Float = 0
    public init(odorLeft: Float = 0, odorRight: Float = 0, taste: Float = 0,
                loomingLeft: Float = 0, loomingRight: Float = 0, touch: Float = 0) {
        self.odorLeft = odorLeft; self.odorRight = odorRight; self.taste = taste
        self.loomingLeft = loomingLeft; self.loomingRight = loomingRight; self.touch = touch
    }
}

/// Measured population firing rates; no food coordinates or destination is permitted here.
public struct NeuralReadout: Codable, Equatable, Sendable {
    public var turnLeftHz: Float = 0
    public var turnRightHz: Float = 0
    public var forwardHz: Float = 0
    public var escapeHz: Float = 0
    public var feedingHz: Float = 0
    public var groomingHz: Float = 0
    public var odorRelayLeftHz: Float = 0
    public var odorRelayRightHz: Float = 0
    public var populationHz: Float = 0
    public var simulatedMilliseconds: Int = 0
    public var computationMilliseconds: Double = 0
    public init(turnLeftHz: Float = 0, turnRightHz: Float = 0, forwardHz: Float = 0,
                escapeHz: Float = 0, feedingHz: Float = 0, groomingHz: Float = 0,
                odorRelayLeftHz: Float = 0, odorRelayRightHz: Float = 0,
                populationHz: Float = 0, simulatedMilliseconds: Int = 0,
                computationMilliseconds: Double = 0) {
        self.turnLeftHz = turnLeftHz; self.turnRightHz = turnRightHz
        self.forwardHz = forwardHz; self.escapeHz = escapeHz; self.feedingHz = feedingHz
        self.groomingHz = groomingHz; self.populationHz = populationHz
        self.odorRelayLeftHz = odorRelayLeftHz; self.odorRelayRightHz = odorRelayRightHz
        self.simulatedMilliseconds = simulatedMilliseconds
        self.computationMilliseconds = computationMilliseconds
    }
}

public enum FlyActivity: String, Codable, Sendable {
    case resting, flying, feeding, escaping, grooming
    public var label: String {
        switch self {
        case .resting: return "쉬는 중"
        case .flying: return "탐색 중"
        case .feeding: return "먹는 중"
        case .escaping: return "피하는 중"
        case .grooming: return "몸 닦는 중"
        }
    }
}

public struct FlyState: Codable, Equatable, Sendable {
    public var position: Point2
    public var heading: Double
    public var speed: Double
    public var activity: FlyActivity
    public init(position: Point2 = Point2(x: 350, y: 260), heading: Double = 0,
                speed: Double = 0, activity: FlyActivity = .resting) {
        self.position = position; self.heading = heading; self.speed = speed; self.activity = activity
    }
}

public struct FoodItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var position: Point2
    public var remaining: Double
    public init(id: UUID = UUID(), position: Point2, remaining: Double = 1) {
        self.id = id; self.position = position; self.remaining = remaining
    }
}

public struct WorldSnapshot: Codable, Sendable {
    public var width: Double = 1000
    public var height: Double = 650
    public var fly = FlyState()
    public var foods: [FoodItem] = []
    public var shadowPosition: Point2? = nil
    public var shadowStrength: Double = 0
    public var sensory = SensoryInput()
    public var neural = NeuralReadout()
    public var motor = MotorCommand()
    public var elapsed: Double = 0
    public var isPaused = false
    public var sensoryEnabled = true
    public var isReady = false
    public var status = "신경망을 불러오는 중…"
    public var error: String? = nil
    public var neuronCount = 0
    public var edgeCount = 0
    public var realtimeFactor: Double = 0
    public init() {}
}

public enum UserAction: Sendable {
    case placeFood(Point2)
    case castShadow(Point2)
    case touchFly
    case clearFood
    case togglePause
    case toggleSensory
    case reset
}
