import Foundation
import NeuroFlyCore

#if canImport(Darwin)
import Darwin
#endif

private struct LearningTrialReport: Codable {
    var kind: FoodKind
    var learningEnabled: Bool
    var simulatedSeconds: Double
    var consumed: Double
    var remaining: Double
    var contactFrames: Int
    var pathDistance: Double
    var firstProbeNeuralDigest: Double
    var firstProbeMovement: Double
    var averageForwardHz: Double
    var averageFeedingHz: Double
    var rawOdorAverage: Double
    var weightedOdorAverage: Double
    var rawSensoryPreserved: Bool
    var initialMemory: FlyMemoryStats
    var finalMemory: FlyMemoryStats
}

private struct LearningPersistenceReport: Codable {
    var encodedBytes: Int
    var equalAfterDecode: Bool
    var restoredProbeNeuralDelta: Double
    var restoredProbeMovementDelta: Double
}

private struct FoodChoiceReport: Codable {
    var learningEnabled: Bool
    var simulatedSeconds: Double
    var bananaConsumed: Double
    var berryConsumed: Double
    var remainingFood: Double
    var firstConsumedKind: FoodKind?
    var pathDistance: Double
    var firstProbeNeuralDigest: Double
    var firstProbeMovement: Double
    var rawSensoryPreserved: Bool
}

private struct LearningReversalReport: Codable {
    var trainedValue: Double
    var reversedValue: Double
    var forgottenValue: Double
    var trainedGain: Float
    var reversedGain: Float
    var forgottenGain: Float
    var threatFrames: Int
    var foodConsumedDuringThreat: Double
}

private struct LearningDiagnosticsReport: Codable {
    var schemaVersion: Int = 1
    var diagnostic = "learning"
    var brainModel: String
    var training: LearningTrialReport
    var untrained: LearningTrialReport
    var trained: LearningTrialReport
    var disabled: LearningTrialReport
    var bananaCueProbe: LearningTrialReport
    var berryCueProbe: LearningTrialReport
    var twoFoodChoice: FoodChoiceReport
    var twoFoodBaseline: FoodChoiceReport
    var persistence: LearningPersistenceReport
    var reversal: LearningReversalReport
    var brainReceivesCoordinates = false
    var checks: [String: Bool]
}

private struct PopulationCaseReport: Codable {
    var individualCount: Int
    var brainCount: Int
    var simulatedSeconds: Double
    var remainingFood: Double
    var consumedByIndividual: [String: Double]
    var memoryStatsByIndividual: [String: FlyMemoryStats]
    var foodConserved: Bool
    var memoryIsolation: Bool
    var independentBrains: Bool
    var rawSensoryPreserved: Bool
    var selectedTouchIsolation: Bool
    var targetedAdvanceIsolation: Bool
    var selectedMemoryIsolation: Bool
    var pausedFrozen: Bool
    var realtimeFactor: Double
    var residentBytes: Int64?
}

private struct PopulationDiagnosticsReport: Codable {
    var schemaVersion: Int = 1
    var diagnostic = "population"
    var brainModel: String
    var cases: [PopulationCaseReport]
    var brainReceivesCoordinates = false
    var checks: [String: Bool]
}

private struct LearningTrialRun {
    var report: LearningTrialReport
    var memory: FlyMemory
}

private extension Array where Element == FoodItem {
    func remaining(of kind: FoodKind) -> Double {
        reduce(0) { partial, food in partial + (food.kind == kind ? food.remaining : 0) }
    }

    var totalRemaining: Double { reduce(0) { $0 + $1.remaining } }
}

private extension NeuralReadout {
    var evolutionDigest: Double {
        Double(turnLeftHz - turnRightHz) + Double(forwardHz) * 0.01 +
            Double(feedingHz) * 0.02 + Double(escapeHz) * 0.03 +
            Double(odorRelayLeftHz + odorRelayRightHz) * 0.001
    }
}

private func evolutionJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func residentBytesForEvolution() -> Int64? {
#if canImport(Darwin)
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
    return Int64(usage.ru_maxrss)
#else
    return nil
#endif
}

extension NeuroFlyMain {
    /// Runs the associative-memory acceptance assay. Rewards come from the
    /// world food-remaining delta after a feeding motor action; no trial writes
    /// a synthetic consumption value into FlyMemory.
    static func runLearningDiagnostics() throws {
        let model = try DataLocator.commandLineModel()
        let dataDirectory = try DataLocator.directory(model: model)
        let brain = try BrainEngine(dataDirectory: dataDirectory, seed: 42, model: model)
        let calibration = try BrainCalibration.measure(brain: brain, seed: 42)

        let training = try runLearningTrial(brain: brain, calibration: calibration,
                                            kind: .banana, initialMemory: nil,
                                            learningEnabled: true, seconds: 30)
        let trainedMemory = training.memory
        let untrained = try runLearningTrial(brain: brain, calibration: calibration,
                                             kind: .banana, initialMemory: FlyMemory(),
                                             learningEnabled: false, seconds: 12)
        let trained = try runLearningTrial(brain: brain, calibration: calibration,
                                           kind: .banana, initialMemory: trainedMemory,
                                           learningEnabled: true, seconds: 12)
        let disabled = try runLearningTrial(brain: brain, calibration: calibration,
                                            kind: .banana, initialMemory: trainedMemory,
                                            learningEnabled: false, seconds: 12)
        let bananaCueProbe = try runLearningTrial(brain: brain, calibration: calibration,
                                                  kind: .banana, initialMemory: trainedMemory,
                                                  learningEnabled: true, seconds: 6)
        let berryCueProbe = try runLearningTrial(brain: brain, calibration: calibration,
                                                 kind: .berry, initialMemory: trainedMemory,
                                                 learningEnabled: true, seconds: 6)
        let twoFoodChoice = try runTwoFoodChoiceTrial(brain: brain, calibration: calibration,
                                                      initialMemory: trainedMemory,
                                                      learningEnabled: true, seconds: 30)
        let twoFoodBaseline = try runTwoFoodChoiceTrial(brain: brain, calibration: calibration,
                                                        initialMemory: FlyMemory(),
                                                        learningEnabled: false, seconds: 30)

        let checkpoint = trainedMemory.memoryForPersistence
        let checkpointData = try JSONEncoder().encode(checkpoint)
        let restoredMemory = try JSONDecoder().decode(FlyMemory.self, from: checkpointData)
        let restored = try runLearningTrial(brain: brain, calibration: calibration,
                                            kind: .banana, initialMemory: restoredMemory,
                                            learningEnabled: true, seconds: 6)
        let persistence = LearningPersistenceReport(
            encodedBytes: checkpointData.count,
            equalAfterDecode: checkpoint == restoredMemory,
            restoredProbeNeuralDelta: abs(restored.report.firstProbeNeuralDigest -
                                          bananaCueProbe.report.firstProbeNeuralDigest),
            restoredProbeMovementDelta: abs(restored.report.firstProbeMovement -
                                            bananaCueProbe.report.firstProbeMovement))

        let reversal = try runThreatReversal(brain: brain, calibration: calibration,
                                             trainedMemory: trainedMemory)
        let trainedGain = training.memory.gain(for: .banana)
        let checks: [String: Bool] = [
            "actualConsumption": training.report.consumed > 0 &&
                training.memory.stats.rewardedIntake > 0,
            "foodGain": trainedGain > 1.0001,
            "graphResponseChanged": abs(trained.report.firstProbeNeuralDigest -
                                         untrained.report.firstProbeNeuralDigest) > 0.001,
            "movementChanged": abs(trained.report.firstProbeMovement -
                                   untrained.report.firstProbeMovement) > 0.5,
            "disabledNeutral": abs(disabled.report.firstProbeNeuralDigest -
                                    untrained.report.firstProbeNeuralDigest) < 0.001,
            "bananaCueDiffersFromBerryCue": abs(bananaCueProbe.report.firstProbeNeuralDigest -
                                                 berryCueProbe.report.firstProbeNeuralDigest) > 0.001,
            "actualFoodChoice": (twoFoodChoice.bananaConsumed + twoFoodChoice.berryConsumed) > 0 &&
                (abs(twoFoodChoice.firstProbeNeuralDigest - twoFoodBaseline.firstProbeNeuralDigest) > 0.001 ||
                 abs(twoFoodChoice.pathDistance - twoFoodBaseline.pathDistance) > 1.0),
            "twoFoodRawSensoryPreserved": twoFoodChoice.rawSensoryPreserved &&
                twoFoodBaseline.rawSensoryPreserved,
            "persistence": persistence.equalAfterDecode &&
                persistence.restoredProbeNeuralDelta < 0.001,
            "rawSensoryPreserved": training.report.rawSensoryPreserved &&
                trained.report.rawSensoryPreserved && disabled.report.rawSensoryPreserved,
            "reversal": reversal.reversedValue < reversal.trainedValue,
            "forgetting": abs(reversal.forgottenValue) < abs(reversal.reversedValue) &&
                abs(Double(reversal.forgottenGain) - 1) < abs(Double(reversal.reversedGain) - 1)
        ]
        let report = LearningDiagnosticsReport(
            brainModel: brain.modelID, training: training.report,
            untrained: untrained.report, trained: trained.report,
            disabled: disabled.report, bananaCueProbe: bananaCueProbe.report,
            berryCueProbe: berryCueProbe.report, twoFoodChoice: twoFoodChoice,
            twoFoodBaseline: twoFoodBaseline, persistence: persistence,
            reversal: reversal, checks: checks)
        print(try evolutionJSON(report))
    }

    /// Runs two and four independent graph-backed agents against one canonical
    /// food list. PopulationWorld owns food conservation; each BrainEngine and
    /// FlyMemory lives behind a distinct profile/seed.
    static func runPopulationDiagnostics() throws {
        let model = try DataLocator.commandLineModel()
        let dataDirectory = try DataLocator.directory(model: model)
        let seeds: [UInt32] = [42, 104729, 209759, 314573]
        let profiles = seeds.enumerated().map { index, seed in
            IndividualProfile(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                              ordinal: index, seed: seed)
        }
        var brains: [UUID: BrainEngine] = [:]
        var calibrations: [UUID: BrainCalibration] = [:]
        for profile in profiles {
            let brain = try BrainEngine(dataDirectory: dataDirectory, seed: profile.seed, model: model)
            brains[profile.id] = brain
            calibrations[profile.id] = try BrainCalibration.measure(brain: brain, seed: profile.seed)
        }
        let two = try runPopulationCase(profiles: Array(profiles.prefix(2)), brains: brains,
                                         calibrations: calibrations)
        let four = try runPopulationCase(profiles: profiles, brains: brains,
                                          calibrations: calibrations)
        let checks = [
            "twoAgents": two.individualCount == 2 && two.brainCount == 2,
            "fourAgents": four.individualCount == 4 && four.brainCount == 4,
            "foodConservation": two.foodConserved && four.foodConserved,
            "memoryIsolation": two.memoryIsolation && four.memoryIsolation,
            "independentBrains": two.independentBrains && four.independentBrains,
            "selectedTouchIsolation": two.selectedTouchIsolation && four.selectedTouchIsolation,
            "targetedAdvanceIsolation": two.targetedAdvanceIsolation && four.targetedAdvanceIsolation,
            "selectedMemoryIsolation": two.selectedMemoryIsolation && four.selectedMemoryIsolation,
            "pausedFrozen": two.pausedFrozen && four.pausedFrozen,
            "rawSensoryPreserved": two.rawSensoryPreserved && four.rawSensoryPreserved
        ]
        let report = PopulationDiagnosticsReport(
            brainModel: brains.values.first?.modelID ?? model.rawValue,
            cases: [two, four], checks: checks)
        print(try evolutionJSON(report))
    }

    private static func runLearningTrial(brain: BrainEngine,
                                         calibration: BrainCalibration,
                                         kind: FoodKind,
                                         initialMemory: FlyMemory?,
                                         learningEnabled: Bool,
                                         seconds: Double) throws -> LearningTrialRun {
        try BrainCalibration.prepare(brain: brain, seed: 42)
        var world = SimulationWorld(width: 1000, height: 650, initialHunger: 0.65)
        world.calibrate(calibration)
        if let initialMemory { world.restoreMemory(initialMemory) }
        if world.memory.learningEnabled != learningEnabled { world.perform(.toggleLearning) }
        let origin = world.snapshot.fly.position
        world.perform(.placeFoodKind(Point2(x: origin.x + 120, y: origin.y), kind))
        let initialStats = world.snapshot.memory.stats
        let frameCount = max(1, Int((seconds * 30).rounded()))
        var consumed = 0.0
        var pathDistance = 0.0
        var contacts = 0
        var rawOdor = 0.0
        var weightedOdor = 0.0
        var forward = 0.0
        var feeding = 0.0
        var firstDigest = 0.0
        var firstMovement = 0.0
        var rawPreserved = true
        var firstSamples = 0
        for tick in 0..<frameCount {
            let milliseconds = tick % 3 == 2 ? 34 : 33
            let dt = Double(milliseconds) / 1000
            let raw = world.sense()
            let neuralInput = world.neuralInput()
            let response = try brain.advance(milliseconds: milliseconds, input: neuralInput,
                                              sensoryEnabled: world.snapshot.sensoryEnabled,
                                              foodDrive: world.snapshot.body.foodDrive)
            let before = world.snapshot
            world.advance(neural: response, input: raw, dt: dt)
            let after = world.snapshot
            consumed += max(0, before.foods.remaining(of: kind) - after.foods.remaining(of: kind))
            pathDistance += before.fly.position.distance(to: after.fly.position)
            if raw.taste > 0 { contacts += 1 }
            rawOdor += Double(raw.odorLeft + raw.odorRight)
            weightedOdor += Double(neuralInput.odorLeft + neuralInput.odorRight)
            forward += Double(response.forwardHz)
            feeding += Double(response.feedingHz)
            rawPreserved = rawPreserved && after.sensory == raw
            if firstSamples < 30 {
                firstDigest += response.evolutionDigest
                firstMovement += before.fly.position.distance(to: after.fly.position)
                firstSamples += 1
            }
        }
        let finalStats = world.snapshot.memory.stats
        return LearningTrialRun(
            report: LearningTrialReport(
                kind: kind, learningEnabled: world.memory.learningEnabled,
                simulatedSeconds: Double(frameCount) / 30,
                consumed: consumed, remaining: world.snapshot.foods.remaining(of: kind),
                contactFrames: contacts, pathDistance: pathDistance,
                firstProbeNeuralDigest: firstDigest / Double(max(1, firstSamples)),
                firstProbeMovement: firstMovement,
                averageForwardHz: forward / Double(frameCount),
                averageFeedingHz: feeding / Double(frameCount),
                rawOdorAverage: rawOdor / Double(frameCount),
                weightedOdorAverage: weightedOdor / Double(frameCount),
                rawSensoryPreserved: rawPreserved,
                initialMemory: initialStats, finalMemory: finalStats),
            memory: world.memory)
    }

    private static func runTwoFoodChoiceTrial(brain: BrainEngine,
                                              calibration: BrainCalibration,
                                              initialMemory: FlyMemory,
                                              learningEnabled: Bool,
                                              seconds: Double) throws -> FoodChoiceReport {
        try BrainCalibration.prepare(brain: brain, seed: 42)
        var world = SimulationWorld(width: 1000, height: 650, initialHunger: 0.65)
        world.restoreMemory(initialMemory)
        world.calibrate(calibration)
        if world.memory.learningEnabled != learningEnabled { world.perform(.toggleLearning) }
        let origin = world.snapshot.fly.position
        // The two targets are symmetric around the forward axis. This is a
        // real two-object world trial; the graph only receives receptor rates.
        // Keep the two virtual odor fields below the receptor clamp at the
        // initial pose so learned identity can change the graph input. The
        // half-full items are still physical world food; this only keeps the
        // symmetric assay from collapsing two fields into the sensor ceiling.
        world.syncFoods([
            FoodItem(id: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
                     position: Point2(x: origin.x + 120, y: origin.y - 45),
                     remaining: 0.5, kind: .banana),
            FoodItem(id: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
                     position: Point2(x: origin.x + 120, y: origin.y + 45),
                     remaining: 0.5, kind: .berry)
        ])
        let frameCount = max(1, Int((seconds * 30).rounded()))
        var bananaConsumed = 0.0
        var berryConsumed = 0.0
        var pathDistance = 0.0
        var firstDigest = 0.0
        var firstMovement = 0.0
        var firstKind: FoodKind?
        var rawPreserved = true
        var firstSamples = 0
        for tick in 0..<frameCount {
            let milliseconds = tick % 3 == 2 ? 34 : 33
            let dt = Double(milliseconds) / 1000
            let raw = world.sense()
            let input = world.neuralInput()
            let response = try brain.advance(milliseconds: milliseconds, input: input,
                                              sensoryEnabled: world.snapshot.sensoryEnabled,
                                              foodDrive: world.snapshot.body.foodDrive)
            let before = world.snapshot
            world.advance(neural: response, input: raw, dt: dt)
            let after = world.snapshot
            let bananaDelta = max(0, before.foods.remaining(of: .banana) - after.foods.remaining(of: .banana))
            let berryDelta = max(0, before.foods.remaining(of: .berry) - after.foods.remaining(of: .berry))
            bananaConsumed += bananaDelta
            berryConsumed += berryDelta
            if firstKind == nil {
                if bananaDelta > 0 { firstKind = .banana }
                else if berryDelta > 0 { firstKind = .berry }
            }
            pathDistance += before.fly.position.distance(to: after.fly.position)
            rawPreserved = rawPreserved && after.sensory == raw
            if firstSamples < 30 {
                firstDigest += response.evolutionDigest
                firstMovement += before.fly.position.distance(to: after.fly.position)
                firstSamples += 1
            }
        }
        return FoodChoiceReport(
            learningEnabled: world.memory.learningEnabled,
            simulatedSeconds: Double(frameCount) / 30,
            bananaConsumed: bananaConsumed, berryConsumed: berryConsumed,
            remainingFood: world.snapshot.foods.totalRemaining,
            firstConsumedKind: firstKind, pathDistance: pathDistance,
            firstProbeNeuralDigest: firstDigest / Double(max(1, firstSamples)),
            firstProbeMovement: firstMovement, rawSensoryPreserved: rawPreserved)
    }

    private static func runThreatReversal(brain: BrainEngine,
                                          calibration: BrainCalibration,
                                          trainedMemory: FlyMemory) throws -> LearningReversalReport {
        try BrainCalibration.prepare(brain: brain, seed: 42)
        var world = SimulationWorld(width: 1000, height: 650, initialHunger: 0.65)
        world.restoreMemory(trainedMemory)
        world.calibrate(calibration)
        let origin = world.snapshot.fly.position
        world.perform(.placeFoodKind(Point2(x: origin.x + 220, y: origin.y), .banana))
        var threatFrames = 0
        var threatConsumed = 0.0
        for tick in 0..<240 {
            let milliseconds = tick % 3 == 2 ? 34 : 33
            let dt = Double(milliseconds) / 1000
            if tick % 15 == 0 { world.perform(.castShadow(world.snapshot.fly.position)) }
            let raw = world.sense()
            if max(raw.loomingLeft, raw.loomingRight, raw.touch) > 0.001 { threatFrames += 1 }
            let response = try brain.advance(milliseconds: milliseconds, input: world.neuralInput(),
                                              sensoryEnabled: world.snapshot.sensoryEnabled,
                                              foodDrive: world.snapshot.body.foodDrive)
            let before = world.snapshot
            world.advance(neural: response, input: raw, dt: dt)
            threatConsumed += max(0, before.foods.totalRemaining - world.snapshot.foods.totalRemaining)
        }
        let reversed = world.memory
        var forgotten = reversed
        forgotten.advance(seconds: FlyMemory.forgettingTimeConstant * 5,
                          cues: FoodCueObservation(), outcome: MemoryOutcome())
        return LearningReversalReport(
            trainedValue: trainedMemory.value(for: .banana),
            reversedValue: reversed.value(for: .banana),
            forgottenValue: forgotten.value(for: .banana),
            trainedGain: trainedMemory.gain(for: .banana),
            reversedGain: reversed.gain(for: .banana),
            forgottenGain: forgotten.gain(for: .banana),
            threatFrames: threatFrames, foodConsumedDuringThreat: threatConsumed)
    }

    private static func runPopulationCase(profiles: [IndividualProfile],
                                           brains: [UUID: BrainEngine],
                                           calibrations: [UUID: BrainCalibration]) throws -> PopulationCaseReport {
        var population = PopulationWorld(width: 1000, height: 650, profiles: profiles)
        for profile in profiles {
            if let calibration = calibrations[profile.id] {
                population.calibrate(calibration, for: profile.id)
            }
            guard let brain = brains[profile.id] else { continue }
            try BrainCalibration.prepare(brain: brain, seed: profile.seed)
        }
        population.perform(.placeFoodKind(Point2(x: 418, y: 338), .banana))
        let initialFood = population.snapshot.foods.totalRemaining
        var consumedByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString, 0.0) })
        var firstDigests = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id.uuidString, 0.0) })
        var firstSeen = Set<String>()
        var rawPreserved = true
        let frameCount = 900
        let start = ProcessInfo.processInfo.systemUptime
        for tick in 0..<frameCount {
            let milliseconds = tick % 3 == 2 ? 34 : 33
            let dt = Double(milliseconds) / 1000
            for profile in profiles {
                guard let brain = brains[profile.id] else { continue }
                let raw = population.sense(profile.id)
                let input = population.neuralInput(profile.id)
                let bodyDrive = population.snapshot.individuals.first(where: { $0.id == profile.id })?.body.foodDrive ?? 1
                let response = try brain.advance(milliseconds: milliseconds, input: input,
                                                 sensoryEnabled: population.snapshot.sensoryEnabled,
                                                 foodDrive: bodyDrive)
                if !firstSeen.contains(profile.id.uuidString) {
                    firstDigests[profile.id.uuidString] = response.evolutionDigest
                    firstSeen.insert(profile.id.uuidString)
                }
                let consumed = population.advance(profile.id, neural: response, input: raw, dt: dt)
                consumedByID[profile.id.uuidString, default: 0] += consumed
                let state = population.snapshot.individuals.first(where: { $0.id == profile.id })
                rawPreserved = rawPreserved && state?.sensory == raw
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let distinct = Set(firstDigests.values.map { Int(($0 * 1000).rounded()) }).count

        // Advance exactly one selected member once more. The selected frame
        // clock must move while every other member's complete snapshot stays
        // stable. Comparing different seeded outputs alone would miss a
        // shared-engine or shared-world bug.
        let targetID = profiles[0].id
        let beforeTargetAdvance = Dictionary(uniqueKeysWithValues:
            population.snapshot.individuals.map { ($0.id, $0) })
        population.selectIndividual(targetID)
        let elapsedBeforeTarget = population.snapshot.elapsed
        let targetRaw = population.sense(targetID)
        let targetInput = population.neuralInput(targetID)
        guard let targetBrain = brains[targetID] else {
            throw BrainEngineError.invalidData("population target brain is missing")
        }
        let targetResponse = try targetBrain.advance(milliseconds: 33, input: targetInput,
                                                     sensoryEnabled: population.snapshot.sensoryEnabled,
                                                     foodDrive: population.snapshot.body.foodDrive)
        let extraConsumed = population.advance(targetID, neural: targetResponse,
                                               input: targetRaw, dt: 0.033)
        consumedByID[targetID.uuidString, default: 0] += extraConsumed
        let afterTargetAdvance = Dictionary(uniqueKeysWithValues:
            population.snapshot.individuals.map { ($0.id, $0) })
        let othersUntouched = profiles.dropFirst().allSatisfy {
            beforeTargetAdvance[$0.id] == afterTargetAdvance[$0.id]
        }
        let targetAdvanced = population.snapshot.elapsed > elapsedBeforeTarget
        let targetedIsolation = targetAdvanced && othersUntouched
        let stats = Dictionary(uniqueKeysWithValues: population.snapshot.individuals.map {
            ($0.id.uuidString, $0.memory.stats)
        })
        let isolated = population.snapshot.individuals.allSatisfy {
            abs($0.memory.stats.rewardedIntake - $0.body.consumedFood) < 1e-8
        }

        // Memory controls are selected-member operations. Verify that clear
        // and toggle do not mutate another member's persisted association.
        let memoryBeforeAction = Dictionary(uniqueKeysWithValues:
            population.snapshot.individuals.map { ($0.id, $0.memory) })
        population.perform(.clearMemory)
        let memoryAfterClear = Dictionary(uniqueKeysWithValues:
            population.snapshot.individuals.map { ($0.id, $0.memory) })
        let clearIsolation = profiles.dropFirst().allSatisfy {
            memoryBeforeAction[$0.id] == memoryAfterClear[$0.id]
        }
        population.perform(.toggleLearning)
        let memoryAfterToggle = Dictionary(uniqueKeysWithValues:
            population.snapshot.individuals.map { ($0.id, $0.memory) })
        let toggleIsolation = profiles.dropFirst().allSatisfy {
            memoryAfterClear[$0.id] == memoryAfterToggle[$0.id]
        }
        let selectedMemoryIsolation = clearIsolation && toggleIsolation

        let remaining = population.snapshot.foods.totalRemaining
        let conserved = abs(initialFood - (remaining + consumedByID.values.reduce(0, +))) < 1e-8
        population.perform(.touchFly)
        let touchValues = profiles.map { population.sense($0.id).touch }
        let touchIsolation = touchValues.first == 1 && touchValues.dropFirst().allSatisfy { $0 == 0 }
        population.perform(.togglePause)
        let pausedBefore = population.snapshot.individuals
        for profile in profiles {
            let input = population.sense(profile.id)
            _ = population.advance(profile.id, neural: NeuralReadout(forwardHz: 100),
                                   input: input, dt: 1)
        }
        let pausedFrozen = pausedBefore == population.snapshot.individuals
        population.perform(.togglePause)
        let actualBrains = profiles.compactMap { brains[$0.id] }
        let actualBrainCount = Set(actualBrains.map { ObjectIdentifier($0) }).count
        return PopulationCaseReport(
            individualCount: profiles.count, brainCount: actualBrainCount,
            simulatedSeconds: Double(frameCount) / 30,
            remainingFood: remaining, consumedByIndividual: consumedByID,
            memoryStatsByIndividual: stats, foodConserved: conserved,
            memoryIsolation: isolated, independentBrains: distinct >= min(2, profiles.count),
            rawSensoryPreserved: rawPreserved, selectedTouchIsolation: touchIsolation,
            targetedAdvanceIsolation: targetedIsolation,
            selectedMemoryIsolation: selectedMemoryIsolation,
            pausedFrozen: pausedFrozen,
            realtimeFactor: elapsed > 0 ? (Double(frameCount) / 30) / elapsed : 0,
            residentBytes: residentBytesForEvolution())
    }
}
