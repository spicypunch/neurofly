import Foundation

public struct MotorCommand: Equatable, Sendable {
    public var speed: Double
    public var turnRate: Double
    public var activity: FlyActivity
    public init(speed: Double = 0, turnRate: Double = 0, activity: FlyActivity = .resting) {
        self.speed = speed; self.turnRate = turnRate; self.activity = activity
    }
}

/// An explicit engineering decoder, not a validated fly musculoskeletal model.
/// Its only input is measured neural activity. It cannot see food or cursor coordinates.
public struct MotorDecoder: Sendable {
    private var baseline = NeuralReadout()
    private var calibration = BrainCalibration()
    private var filteredTurn: Double = 0
    private var filteredOdorLeft: Double = 0
    private var filteredOdorRight: Double = 0
    public init() {}
    public mutating func calibrate(_ baseline: NeuralReadout) {
        self.baseline = baseline
        filteredTurn = 0
    }

    public mutating func calibrate(_ calibration: BrainCalibration) {
        self.calibration = calibration
        calibrate(calibration.baseline)
        filteredOdorLeft = 0; filteredOdorRight = 0
    }

    public mutating func decode(_ neural: NeuralReadout, dt: Double) -> MotorCommand {
        let left = Double(neural.turnLeftHz)
        let right = Double(neural.turnRightHz)
        let bias = Double(baseline.turnLeftHz - baseline.turnRightHz)
        let odorBlend = 1 - exp(-max(0, dt) / 0.5)
        filteredOdorLeft += (Double(neural.odorRelayLeftHz) - filteredOdorLeft) * odorBlend
        filteredOdorRight += (Double(neural.odorRelayRightHz) - filteredOdorRight) * odorBlend
        let odorTotal = filteredOdorLeft + filteredOdorRight
        let odorActive = odorTotal > 30 && !calibration.odorBalance.isEmpty
        let expectedLeft = calibration.balancedLeftFraction(total: odorTotal)
        let contrast = odorTotal > 0 ? filteredOdorLeft / odorTotal - expectedLeft : 0
        // Measured PN contrast steers the simplified body after bilateral bias
        // correction. This is an engineered decoder, not a claim about flight DNs.
        let turn = odorActive ? contrast * 55 : (left - right - bias) * 0.055
        let targetTurn = max(-2.8, min(2.8, turn))
        let blend = 1 - exp(-max(0, dt) / 0.12)
        filteredTurn += (targetTurn - filteredTurn) * blend

        let forward = max(0, Double(neural.forwardHz))
        let speed = min(120, forward * 3.2) * (odorActive ? 0.45 : 1)
        let escape = neural.escapeHz > max(8, baseline.escapeHz + 10)
        let feeding = neural.feedingHz > max(25, baseline.feedingHz + 20)
        let grooming = neural.groomingHz > max(10, baseline.groomingHz + 15)
        if escape { return MotorCommand(speed: min(260, 120 + Double(neural.escapeHz) * 1.5), turnRate: filteredTurn, activity: .escaping) }
        if feeding { return MotorCommand(speed: 0, turnRate: 0, activity: .feeding) }
        if grooming { return MotorCommand(speed: 0, turnRate: 0, activity: .grooming) }
        return MotorCommand(speed: speed, turnRate: filteredTurn, activity: speed > 2 ? .flying : .resting)
    }
}

public struct SimulationWorld: Sendable {
    public private(set) var snapshot = WorldSnapshot()
    private var shadowAge: Double? = nil
    private var touchRemaining: Double = 0
    private var decoder = MotorDecoder()

    public init(width: Double = 1000, height: Double = 650) {
        snapshot.width = max(180, width); snapshot.height = max(180, height)
        snapshot.fly.position = Point2(x: snapshot.width * 0.4, y: snapshot.height * 0.52)
    }

    public mutating func calibrate(_ baseline: NeuralReadout) { decoder.calibrate(baseline) }
    public mutating func calibrate(_ calibration: BrainCalibration) { decoder.calibrate(calibration) }

    public mutating func resize(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width >= 180, height >= 180 else { return }
        let sx = width / snapshot.width, sy = height / snapshot.height
        func scaled(_ p: Point2) -> Point2 { Point2(x: p.x * sx, y: p.y * sy) }
        snapshot.fly.position = scaled(snapshot.fly.position)
        for i in snapshot.foods.indices { snapshot.foods[i].position = scaled(snapshot.foods[i].position) }
        if let shadow = snapshot.shadowPosition { snapshot.shadowPosition = scaled(shadow) }
        snapshot.width = width; snapshot.height = height
    }

    public mutating func perform(_ action: UserAction) {
        switch action {
        case .placeFood(let p):
            guard p.x.isFinite, p.y.isFinite else { return }
            if snapshot.foods.count >= 8 { snapshot.foods.removeFirst() }
            snapshot.foods.append(FoodItem(position: constrained(p, inset: 28)))
        case .castShadow(let p):
            guard p.x.isFinite, p.y.isFinite else { return }
            snapshot.shadowPosition = constrained(p, inset: 0)
            shadowAge = 0; snapshot.shadowStrength = 0.01
        case .touchFly: touchRemaining = 0.35
        case .clearFood: snapshot.foods.removeAll()
        case .togglePause: snapshot.isPaused.toggle()
        case .toggleSensory: snapshot.sensoryEnabled.toggle()
        case .reset:
            let width = snapshot.width, height = snapshot.height
            self = SimulationWorld(width: width, height: height)
        }
    }

    public func sense() -> SensoryInput {
        guard snapshot.sensoryEnabled else { return SensoryInput() }
        let fly = snapshot.fly
        let forward = Point2(x: cos(fly.heading), y: sin(fly.heading))
        let left = Point2(x: -forward.y, y: forward.x)
        // Screen-space sensory baselines are intentionally exaggerated so this
        // coarse 2D body can resolve an odor gradient. They are not fly anatomy.
        let antennaL = Point2(x: fly.position.x + forward.x * 17 + left.x * 35,
                             y: fly.position.y + forward.y * 17 + left.y * 35)
        let antennaR = Point2(x: fly.position.x + forward.x * 17 - left.x * 35,
                             y: fly.position.y + forward.y * 17 - left.y * 35)
        let mouth = Point2(x: fly.position.x + forward.x * 18, y: fly.position.y + forward.y * 18)
        var input = SensoryInput()
        // A virtual fruit emits an isotropic Gaussian odor field. It is not a food target vector.
        for food in snapshot.foods where food.remaining > 0 {
            let radius = 110.0
            func concentration(_ p: Point2) -> Float {
                let d = p.distance(to: food.position)
                return Float(food.remaining * exp(-(d * d) / (2 * radius * radius)))
            }
            input.odorLeft += concentration(antennaL)
            input.odorRight += concentration(antennaR)
            if mouth.distance(to: food.position) <= 27 { input.taste = 1 }
        }
        input.odorLeft = min(1, input.odorLeft)
        input.odorRight = min(1, input.odorRight)
        if let center = snapshot.shadowPosition, let age = shadowAge, age < 0.7 {
            let d = max(15, fly.position.distance(to: center))
            let radius = 8 + 220 * age
            let angularExpansion = 2 * 220 * d / (d * d + radius * radius)
            let drive = min(1, angularExpansion / 2) * max(0, 1 - d / 700)
            let bearing = atan2(center.y - fly.position.y, center.x - fly.position.x) - fly.heading
            let lateral = sin(bearing)
            input.loomingLeft = Float(drive * (0.55 + 0.45 * lateral))
            input.loomingRight = Float(drive * (0.55 - 0.45 * lateral))
        }
        input.touch = touchRemaining > 0 ? 1 : 0
        return input
    }

    public mutating func advance(neural: NeuralReadout, input: SensoryInput, dt: Double) {
        guard !snapshot.isPaused, dt.isFinite, dt > 0 else { return }
        let step = min(dt, 0.1)
        snapshot.neural = neural; snapshot.sensory = input
        let motor = decoder.decode(neural, dt: step)
        advanceBody(motor: motor, dt: step)
        snapshot.elapsed += step
        touchRemaining = max(0, touchRemaining - step)
        if let age = shadowAge {
            let next = age + step
            shadowAge = next
            snapshot.shadowStrength = min(1, next / 0.5) * max(0, 1 - max(0, next - 0.7) / 0.6)
            if next > 1.3 { shadowAge = nil; snapshot.shadowPosition = nil; snapshot.shadowStrength = 0 }
        }
    }

    /// Kept separate so tests can prove body motion depends on motor signals, not objects.
    public mutating func advanceBody(motor: MotorCommand, dt: Double) {
        guard dt.isFinite, dt > 0, motor.speed.isFinite, motor.turnRate.isFinite else { return }
        snapshot.fly.heading += motor.turnRate * dt
        snapshot.fly.heading = atan2(sin(snapshot.fly.heading), cos(snapshot.fly.heading))
        let blend = 1 - exp(-dt / (motor.activity == .feeding || motor.activity == .grooming ? 0.04 : 0.16))
        snapshot.fly.speed += (max(0, motor.speed) - snapshot.fly.speed) * blend
        snapshot.fly.position.x += cos(snapshot.fly.heading) * snapshot.fly.speed * dt
        snapshot.fly.position.y += sin(snapshot.fly.heading) * snapshot.fly.speed * dt
        snapshot.fly.activity = motor.activity
        // Physical enclosure collisions, independent of food and neural decision making.
        let inset = 24.0
        if snapshot.fly.position.x < inset || snapshot.fly.position.x > snapshot.width - inset {
            snapshot.fly.position.x = max(inset, min(snapshot.width - inset, snapshot.fly.position.x))
            snapshot.fly.heading = .pi - snapshot.fly.heading
            snapshot.fly.speed *= 0.7
        }
        if snapshot.fly.position.y < inset || snapshot.fly.position.y > snapshot.height - inset {
            snapshot.fly.position.y = max(inset, min(snapshot.height - inset, snapshot.fly.position.y))
            snapshot.fly.heading = -snapshot.fly.heading
            snapshot.fly.speed *= 0.7
        }
        if motor.activity == .feeding {
            let mouth = Point2(x: snapshot.fly.position.x + cos(snapshot.fly.heading) * 18,
                               y: snapshot.fly.position.y + sin(snapshot.fly.heading) * 18)
            for i in snapshot.foods.indices where mouth.distance(to: snapshot.foods[i].position) <= 30 {
                snapshot.foods[i].remaining = max(0, snapshot.foods[i].remaining - dt * 0.065)
            }
            snapshot.foods.removeAll { $0.remaining <= 0 }
        }
    }

    private func constrained(_ p: Point2, inset: Double) -> Point2 {
        Point2(x: max(inset, min(snapshot.width - inset, p.x)), y: max(inset, min(snapshot.height - inset, p.y)))
    }
}
