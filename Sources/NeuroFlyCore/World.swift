import Foundation

public struct MotorCommand: Codable, Equatable, Sendable {
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
    private var filteredDirection: Double = 0
    private var filteredOdorLeft: Double = 0
    private var filteredOdorRight: Double = 0
    private var odorTrendReference: Double = 0
    private var odorObservationTime: Double = 0
    private var searchRemaining: Double = 0
    private var searchDirection: Double = 1
    private var searchCooldown: Double = 0
    private var relayWasActive = false
    private var odorMemoryRemaining: Double = 0
    private var stableOdorCourseTime: Double = 0
    private var feedingEvidence: Double = 0
    public init() {}
    public mutating func calibrate(_ baseline: NeuralReadout) {
        self.baseline = baseline
        self.calibration = BrainCalibration(baseline: baseline)
        filteredTurn = 0
        filteredDirection = 0
        filteredOdorLeft = 0; filteredOdorRight = 0
        odorTrendReference = 0; odorObservationTime = 0
        searchRemaining = 0; searchDirection = 1; searchCooldown = 0
        relayWasActive = false; odorMemoryRemaining = 0; feedingEvidence = 0
        stableOdorCourseTime = 0
    }

    public mutating func calibrate(_ calibration: BrainCalibration) {
        calibrate(calibration.baseline)
        self.calibration = calibration
    }

    public mutating func decode(_ neural: NeuralReadout, dt: Double) -> MotorCommand {
        let left = Double(neural.turnLeftHz)
        let right = Double(neural.turnRightHz)
        let bias = Double(baseline.turnLeftHz - baseline.turnRightHz)
        // The legacy FlyWire calibration has simulated relay rates comfortably
        // above 30 Hz. Male CNS has a sparser, explicitly mapped relay: the
        // measured long-range signal can start around 20 Hz and then decay. Keep the old gate for
        // legacy calibration and use the measured Male threshold when it is
        // available, so weak neural evidence is not discarded before the
        // history-based search can react.
        let maleCalibration = calibration.odorActivationThresholdHz != nil
        let odorThreshold = max(0.1, calibration.odorActivationThresholdHz ?? 30)
        let rawRelayTotal = Double(neural.odorRelayLeftHz + neural.odorRelayRightHz)
        let rawActive = rawRelayTotal > odorThreshold
        if rawActive && !relayWasActive {
            filteredOdorLeft = Double(neural.odorRelayLeftHz)
            filteredOdorRight = Double(neural.odorRelayRightHz)
        }
        relayWasActive = rawActive
        let odorBlend = 1 - exp(-max(0, dt) / 0.2)
        filteredOdorLeft += (Double(neural.odorRelayLeftHz) - filteredOdorLeft) * odorBlend
        filteredOdorRight += (Double(neural.odorRelayRightHz) - filteredOdorRight) * odorBlend
        let odorTotal = filteredOdorLeft + filteredOdorRight
        let relayActive = odorTotal > odorThreshold &&
            (!calibration.odorBalance.isEmpty || !calibration.odorResponses.isEmpty)
        if maleCalibration && rawActive {
            // Preserve a short observation window after a weak Male relay
            // drops below its activation threshold. Without this bounded
            // neural history, the first low-rate plume sample disappears
            // before the existing falling-signal search can react.
            odorMemoryRemaining = 2.5
        } else if maleCalibration {
            odorMemoryRemaining = max(0, odorMemoryRemaining - max(0, dt))
        }
        let odorObserved = relayActive || (maleCalibration && odorMemoryRemaining > 0)
        let expectedLeft = calibration.balancedLeftFraction(total: odorTotal)
        let rawContrast = odorTotal > 0 ? filteredOdorLeft / odorTotal - expectedLeft : 0
        let contrast = rawContrast.sign == .minus ? min(0, rawContrast + 0.006) : max(0, rawContrast - 0.006)
        let rawDirection = calibration.odorResponses.isEmpty ? contrast * 20 :
            calibration.estimateDirection(leftHz: filteredOdorLeft, rightHz: filteredOdorRight)
        // Male relay rates are sparse and can flip between neighboring
        // calibration labels at long range. Preserve a short neural history
        // before translating that readout into a body turn; this filters the
        // readout itself and does not introduce a food bearing or coordinate.
        let direction: Double
        if maleCalibration {
            let directionBlend = 1 - exp(-max(0, dt) / 0.35)
            let directionTarget = relayActive ? rawDirection : 0
            filteredDirection += (directionTarget - filteredDirection) * directionBlend
            direction = max(-1, min(1, filteredDirection))
        } else {
            direction = rawDirection
        }
        let escape = neural.escapeHz > max(8, baseline.escapeHz + 10)
        let feedingThreshold = calibration.feedingThresholdHz.map(Float.init) ??
            max(25, baseline.feedingHz + 20)
        // A single stochastic MN9 burst is not enough to establish contact.
        // Male CNS's measured midpoint is close to its occasional no-input
        // peaks, so require a short neural-output history unless the signal
        // is well above the calibrated separation. This keeps feeding driven
        // by the output stream while preventing a lone background spike from
        // cancelling an odor search.
        let feedingSignal = neural.feedingHz > feedingThreshold
        if maleCalibration && feedingSignal {
            feedingEvidence = min(0.25, feedingEvidence + max(0, dt))
        } else if maleCalibration {
            feedingEvidence = max(0, feedingEvidence - max(0, dt) * 2)
        }
        let feeding = maleCalibration
            ? feedingSignal &&
                (feedingEvidence >= 0.1 || neural.feedingHz >= feedingThreshold + 5)
            : feedingSignal
        let grooming = neural.groomingHz > max(10, baseline.groomingHz + 15)
        if escape || feeding || grooming {
            // Contact/escape interrupts a search instead of letting an unseen
            // search timer run underneath it and leak into the next flight.
            searchRemaining = 0; searchCooldown = 1.2
            odorTrendReference = odorTotal
            filteredTurn = 0
            if escape {
                return MotorCommand(speed: min(260, 120 + Double(neural.escapeHz) * 1.5),
                    turnRate: max(-2.8, min(2.8, (left - right - bias) * 0.055)), activity: .escaping)
            }
            return MotorCommand(activity: feeding ? .feeding : .grooming)
        }
        let trendBlend = 1 - exp(-max(0, dt) / 1.5)
        odorTrendReference += (odorTotal - odorTrendReference) * trendBlend
        odorObservationTime = odorObserved ? odorObservationTime + dt : 0
        searchCooldown = max(0, searchCooldown - dt)
        let trend = (odorTotal - odorTrendReference) / max(30, odorTrendReference)
        // A bilateral sample cannot distinguish straight ahead from directly
        // behind. If measured relay activity falls while moving, turn briefly
        // to sample again. This is a body adapter using neural history only;
        // there is no food position, sensed concentration, or target bearing.
        let lostWeakRelay = maleCalibration && !relayActive && odorMemoryRemaining > 0 &&
            odorObservationTime > 0.3
        // During a directional correction, the two PN rates also change as
        // the antennae rotate through the field. Do not mistake that change
        // for leaving the plume and override an ongoing corrective turn.
        let stableCourse = !maleCalibration || (abs(direction) < 0.25 && abs(filteredTurn) < 0.35)
        stableOdorCourseTime = stableCourse ? stableOdorCourseTime + max(0, dt) : 0
        let courseEstablished = !maleCalibration || stableOdorCourseTime > 1
        if odorObserved && ((odorObservationTime > 1.5 && courseEstablished) || lostWeakRelay) && trend < -0.035 &&
            searchRemaining <= 0 && searchCooldown <= 0 {
            searchRemaining = 1.8
            searchDirection = direction >= 0 ? 1 : -1
        }
        let searching = searchRemaining > 0
        if searching {
            searchRemaining = max(0, searchRemaining - dt)
            if searchRemaining <= 0 { searchCooldown = 1.2 }
        }
        // Measured PN contrast steers the simplified body after bilateral bias
        // correction. This is an engineered decoder, not a claim about flight DNs.
        let steeringGain = maleCalibration ? 1.3 : 2.3
        // When the two relays become ambiguous near a strong odor source,
        // retain Male CNS's descending steering at its normal movement gain.
        // Suppressing it here made a near-source lateral correction too weak
        // to follow the signal before the body passed the contact region.
        let descendingGain = maleCalibration ? 0.055 : 0.015
        let odorTurn = abs(direction) > 0.15 ? direction * steeringGain : (left - right - bias) * descendingGain
        let turn = searching ? searchDirection * 1.8 :
            (odorObserved ? (odorObservationTime > 0.3 ? odorTurn : 0) : (left - right - bias) * 0.055)
        let targetTurn = max(-2.8, min(2.8, turn))
        let blend = 1 - exp(-max(0, dt) / 0.12)
        filteredTurn += (targetTurn - filteredTurn) * blend

        let forward = max(0, Double(neural.forwardHz))
        let speed = min(120, forward * 3.2) * (searching ? 0.25 : odorObserved ? 0.85 - 0.5 * min(1, abs(direction)) : 1)
        return MotorCommand(speed: speed, turnRate: filteredTurn, activity: speed > 2 ? .flying : .resting)
    }
}

public struct SimulationWorld: Sendable {
    public private(set) var snapshot = WorldSnapshot()
    private var shadowAge: Double? = nil
    private var touchRemaining: Double = 0
    private var decoder = MotorDecoder()

    public init(width: Double = 1000, height: Double = 650, initialHunger: Double = 0.65,
                initialPosition: Point2? = nil) {
        snapshot.width = max(180, width); snapshot.height = max(180, height)
        if let initialPosition, initialPosition.x.isFinite, initialPosition.y.isFinite {
            snapshot.fly.position = Point2(
                x: max(24, min(snapshot.width - 24, initialPosition.x)),
                y: max(24, min(snapshot.height - 24, initialPosition.y)))
        } else {
            snapshot.fly.position = Point2(x: snapshot.width * 0.4, y: snapshot.height * 0.52)
        }
        snapshot.body = BodyState(hunger: initialHunger)
    }

    public mutating func calibrate(_ baseline: NeuralReadout) {
        decoder.calibrate(baseline)
        resetNeuralObservation()
    }

    public mutating func calibrate(_ calibration: BrainCalibration) {
        decoder.calibrate(calibration)
        resetNeuralObservation()
    }

    /// Clears rates produced by the previous connectome after a calibration or
    /// model change. Body, memory, food, and environment timing stay intact.
    public mutating func resetNeuralObservation() {
        snapshot.neural = NeuralReadout()
        snapshot.motor = MotorCommand()
    }

    /// Synchronizes the shared food environment before a population member is
    /// sensed or advanced. PopulationWorld is the canonical owner; this copy
    /// exists only so the established single-world sensing and consumption
    /// code can be reused without passing coordinates into the brain.
    public mutating func syncFoods(_ foods: [FoodItem]) {
        snapshot.foods = foods
    }

    public var memory: FlyMemory { snapshot.memory }

    /// Restores only associative memory. Brain membrane state and body motion
    /// remain owned by their existing runtime and are intentionally untouched.
    public mutating func restoreMemory(_ value: FlyMemory) {
        snapshot.memory = value.preparedForResume()
        snapshot.learningEnabled = snapshot.memory.learningEnabled
    }

    /// Copies shared environment timing when a new member joins a running
    /// colony. Individual position, body, neural, and memory state stay new.
    public mutating func inheritEnvironment(from other: SimulationWorld) {
        snapshot.foods = other.snapshot.foods
        snapshot.shadowPosition = other.snapshot.shadowPosition
        snapshot.shadowStrength = other.snapshot.shadowStrength
        snapshot.elapsed = other.snapshot.elapsed
        snapshot.isPaused = other.snapshot.isPaused
        snapshot.sensoryEnabled = other.snapshot.sensoryEnabled
        shadowAge = other.shadowAge
    }

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
        case .placeFoodKind(let p, let kind):
            guard p.x.isFinite, p.y.isFinite else { return }
            if snapshot.foods.count >= 8 { snapshot.foods.removeFirst() }
            snapshot.foods.append(FoodItem(position: constrained(p, inset: 28), kind: kind))
        case .castShadow(let p):
            guard p.x.isFinite, p.y.isFinite else { return }
            snapshot.shadowPosition = constrained(p, inset: 0)
            shadowAge = 0; snapshot.shadowStrength = 0.01
        case .touchFly: touchRemaining = 0.35
        case .clearFood: snapshot.foods.removeAll()
        case .togglePause: snapshot.isPaused.toggle()
        case .toggleSensory: snapshot.sensoryEnabled.toggle()
        case .toggleLearning:
            var next = snapshot.memory
            next.learningEnabled.toggle()
            snapshot.memory = next
            snapshot.learningEnabled = next.learningEnabled
        case .clearMemory:
            var next = snapshot.memory
            next.reset()
            snapshot.memory = next
            snapshot.learningEnabled = next.learningEnabled
        case .reset:
            let width = snapshot.width, height = snapshot.height
            self = SimulationWorld(width: width, height: height)
        case .addIndividual, .removeSelectedIndividual, .selectIndividual,
             .switchBrainModel:
            // Population-only actions are handled by PopulationWorld. Keep
            // SimulationWorld source compatible for single-fly diagnostics.
            break
        }
    }

    public func sense() -> SensoryInput {
        guard snapshot.sensoryEnabled else { return SensoryInput() }
        let fly = snapshot.fly
        let points = receptorPoints(for: fly)
        var input = SensoryInput()
        // A virtual fruit emits an isotropic Gaussian odor field. It is not a food target vector.
        for food in snapshot.foods where food.remaining > 0 {
            let radius = 180.0
            func concentration(_ p: Point2) -> Float {
                let d = p.distance(to: food.position)
                return Float(food.remaining * exp(-(d * d) / (2 * radius * radius)))
            }
            input.odorLeft += concentration(points.left)
            input.odorRight += concentration(points.right)
            if points.mouth.distance(to: food.position) <= 27 { input.taste = 1 }
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

    /// Coordinate-free cue summary used only by the associative-memory layer.
    /// The brain still receives the six-channel `SensoryInput`; no object
    /// position or target bearing crosses this boundary.
    public func memoryCues() -> FoodCueObservation {
        guard snapshot.sensoryEnabled else { return FoodCueObservation() }
        let points = receptorPoints(for: snapshot.fly)
        var cues = FoodCueObservation()
        for food in snapshot.foods where food.remaining > 0 {
            let radius = 180.0
            func concentration(_ point: Point2) -> Float {
                let distance = point.distance(to: food.position)
                return Float(food.remaining * exp(-(distance * distance) / (2 * radius * radius)))
            }
            var cue = cues[food.kind]
            cue.left = min(1, cue.left + concentration(points.left))
            cue.right = min(1, cue.right + concentration(points.right))
            cues[food.kind] = cue
        }
        let raw = sense()
        cues.threat = max(raw.loomingLeft, raw.loomingRight, raw.touch)
        return cues
    }

    /// Raw receptor output weighted by this individual's learned food memory.
    /// `advance` receives the raw signal separately so the inspector can show
    /// what the virtual receptors sensed and learning can use the same cue.
    public func neuralInput() -> SensoryInput {
        snapshot.memory.weightedSensoryInput(raw: sense(), cues: memoryCues())
    }

    public mutating func advance(neural: NeuralReadout, input: SensoryInput, dt: Double) {
        guard !snapshot.isPaused, dt.isFinite, dt > 0 else { return }
        let step = min(dt, 0.1)
        let cues = memoryCues()
        snapshot.neural = neural; snapshot.sensory = input
        let motor = decoder.decode(neural, dt: step)
        snapshot.motor = motor
        let outcome = advanceBody(motor: motor, dt: step)
        var memoryOutcome = outcome
        memoryOutcome.threat = Double(max(input.loomingLeft, input.loomingRight, input.touch))
        var nextMemory = snapshot.memory
        nextMemory.advance(seconds: step, cues: cues, outcome: memoryOutcome)
        snapshot.memory = nextMemory
        snapshot.learningEnabled = nextMemory.learningEnabled
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
    @discardableResult
    public mutating func advanceBody(motor: MotorCommand, dt: Double) -> MemoryOutcome {
        guard !snapshot.isPaused, dt.isFinite, dt > 0, motor.speed.isFinite, motor.turnRate.isFinite else {
            return MemoryOutcome()
        }
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
        var outcome = MemoryOutcome()
        if motor.activity == .feeding {
            let mouth = Point2(x: snapshot.fly.position.x + cos(snapshot.fly.heading) * 18,
                               y: snapshot.fly.position.y + sin(snapshot.fly.heading) * 18)
            for i in snapshot.foods.indices where mouth.distance(to: snapshot.foods[i].position) <= 30 {
                let consumed = min(snapshot.foods[i].remaining, dt * 0.065)
                snapshot.foods[i].remaining -= consumed
                outcome[snapshot.foods[i].kind] += consumed
            }
            snapshot.foods.removeAll { $0.remaining <= 0 }
        }
        let totalConsumed = outcome.bananaConsumed + outcome.berryConsumed
        snapshot.body.advance(seconds: dt, speed: snapshot.fly.speed, foodConsumed: totalConsumed)
        return outcome
    }

    private func receptorPoints(for fly: FlyState) -> (left: Point2, right: Point2, mouth: Point2) {
        let forward = Point2(x: cos(fly.heading), y: sin(fly.heading))
        let left = Point2(x: -forward.y, y: forward.x)
        // Screen-space sensory baselines are intentionally exaggerated so this
        // coarse 2D body can resolve an odor gradient. They are not fly anatomy.
        let antennaL = Point2(x: fly.position.x + forward.x * 17 + left.x * 35,
                              y: fly.position.y + forward.y * 17 + left.y * 35)
        let antennaR = Point2(x: fly.position.x + forward.x * 17 - left.x * 35,
                              y: fly.position.y + forward.y * 17 - left.y * 35)
        let mouth = Point2(x: fly.position.x + forward.x * 18,
                           y: fly.position.y + forward.y * 18)
        return (antennaL, antennaR, mouth)
    }

    private func constrained(_ p: Point2, inset: Double) -> Point2 {
        Point2(x: max(inset, min(snapshot.width - inset, p.x)), y: max(inset, min(snapshot.height - inset, p.y)))
    }
}
