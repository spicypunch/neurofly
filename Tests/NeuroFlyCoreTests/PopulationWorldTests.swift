import XCTest
@testable import NeuroFlyCore

final class PopulationWorldTests: XCTestCase {
    func testPopulationIsBoundedAndSelectionSurvivesRemoval() {
        var world = PopulationWorld()
        XCTAssertEqual(world.individualCount, 1)
        let first = world.selectedIndividualID

        world.perform(.addIndividual)
        world.perform(.addIndividual)
        world.perform(.addIndividual)
        XCTAssertEqual(world.individualCount, 4)
        world.perform(.addIndividual)
        XCTAssertEqual(world.individualCount, 4)

        let second = world.individualIDs[1]
        world.perform(.selectIndividual(second))
        XCTAssertEqual(world.selectedIndividualID, second)
        world.perform(.removeSelectedIndividual)
        XCTAssertEqual(world.individualCount, 3)
        XCTAssertNotEqual(world.selectedIndividualID, second)
        XCTAssertTrue(world.individualIDs.contains(first))

        world.perform(.removeSelectedIndividual)
        world.perform(.removeSelectedIndividual)
        world.perform(.removeSelectedIndividual)
        XCTAssertEqual(world.individualCount, 1)
    }

    func testEachIndividualOwnsBodyAndDecoderHistory() {
        var world = PopulationWorld(width: 1000, height: 650)
        world.perform(.addIndividual)
        let ids = world.individualIDs
        let before = Dictionary(uniqueKeysWithValues: world.snapshot.individuals.map { ($0.id, $0.body) })

        let first = ids[0]
        let input = world.neuralInput(first)
        _ = world.advance(first, neural: NeuralReadout(), input: input, dt: 1)

        let after = Dictionary(uniqueKeysWithValues: world.snapshot.individuals.map { ($0.id, $0.body) })
        XCTAssertGreaterThan(after[first]!.hunger, before[first]!.hunger)
        XCTAssertEqual(after[ids[1]], before[ids[1]])
    }

    func testSharedFoodIsConsumedOncePerMemberAgainstCanonicalRemaining() {
        var world = PopulationWorld(width: 1000, height: 650)
        world.perform(.addIndividual)
        let ids = world.individualIDs
        let positions = world.snapshot.individuals.map { $0.fly.position }
        let firstMouth = Point2(x: positions[0].x + 18, y: positions[0].y)
        let secondMouth = Point2(x: positions[1].x + 18, y: positions[1].y)
        let sharedPosition = Point2(x: (firstMouth.x + secondMouth.x) / 2,
                                    y: (firstMouth.y + secondMouth.y) / 2)
        world.perform(.placeFood(sharedPosition))

        let forcedFeeding = NeuralReadout(feedingHz: 100)
        for id in ids {
            let input = world.neuralInput(id)
            _ = world.advance(id, neural: forcedFeeding, input: input, dt: 0.1)
        }

        let remaining = world.snapshot.foods.reduce(0) { $0 + $1.remaining }
        XCTAssertEqual(remaining, 1 - (2 * 0.1 * 0.065), accuracy: 1e-12)
        let totalConsumed = world.snapshot.individuals.reduce(0.0) {
            $0 + $1.body.consumedFood
        }
        XCTAssertEqual(totalConsumed, 2 * 0.1 * 0.065, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(remaining, 1)
        XCTAssertGreaterThanOrEqual(remaining, 0)
    }

    func testPauseFreezesAllMembersAndResetPreservesProfiles() {
        var world = PopulationWorld(width: 900, height: 600)
        world.perform(.addIndividual)
        let profiles = world.profiles
        let selected = world.selectedIndividualID
        let before = world.snapshot

        world.perform(.togglePause)
        for id in world.individualIDs {
            _ = world.advance(id, neural: NeuralReadout(forwardHz: 100),
                              input: world.neuralInput(id), dt: 1)
        }
        XCTAssertEqual(world.snapshot.individuals.map(\.body), before.individuals.map(\.body))

        world.perform(.reset)
        XCTAssertEqual(world.profiles, profiles)
        XCTAssertEqual(world.selectedIndividualID, selected)
        XCTAssertTrue(world.snapshot.foods.isEmpty)
        XCTAssertTrue(world.snapshot.individuals.allSatisfy { $0.body.consumedFood == 0 })
        XCTAssertFalse(world.snapshot.isPaused)
    }

    func testShadowAndSensoryFlagsAreSharedButSelectedTouchIsLocal() {
        var world = PopulationWorld(width: 1000, height: 650)
        world.perform(.addIndividual)
        let ids = world.individualIDs
        let selected = world.selectedIndividualID
        world.perform(.touchFly)
        XCTAssertEqual(world.sense(selected).touch, 1)
        XCTAssertEqual(world.sense(ids[1]).touch, 0)

        world.perform(.toggleSensory)
        XCTAssertFalse(world.snapshot.sensoryEnabled)
        for id in ids {
            XCTAssertEqual(world.neuralInput(id), SensoryInput())
        }
    }

    func testProfilesRoundTripCurrentMemoryAndResetClearsIt() {
        var memory = FlyMemory()
        memory.advance(seconds: 2,
                       cues: FoodCueObservation(banana: BilateralFoodCue(left: 1, right: 1)),
                       outcome: MemoryOutcome(bananaConsumed: 1))
        let id = UUID()
        let profile = IndividualProfile(id: id, ordinal: 7, seed: 9001, memory: memory)
        var world = PopulationWorld(profiles: [profile])
        XCTAssertEqual(world.profiles.first?.id, id)
        XCTAssertEqual(world.profiles.first?.seed, 9001)
        XCTAssertEqual(world.profiles.first?.memory, memory.memoryForPersistence)
        XCTAssertGreaterThan(world.snapshot.individuals[0].memory.stats.bananaValue, 0)

        world.perform(.toggleLearning)
        XCTAssertFalse(world.snapshot.memory.learningEnabled)
        world.perform(.clearMemory)
        XCTAssertEqual(world.snapshot.memory.stats.bananaValue, 0)
        world.perform(.reset)
        XCTAssertEqual(world.snapshot.individuals[0].memory.stats.rewardedIntake, 0)
        XCTAssertEqual(world.profiles.first?.id, id)
        XCTAssertEqual(world.profiles.first?.seed, 9001)
    }

    func testFoodKindIsSharedAndNeuralInputKeepsThreatChannelsUnweighted() {
        var world = PopulationWorld(width: 1000, height: 650)
        let fly = world.snapshot.fly.position
        world.perform(.placeFoodKind(Point2(x: fly.x + 18, y: fly.y), .berry))
        let raw = world.sense(world.selectedIndividualID)
        let weighted = world.neuralInput(world.selectedIndividualID)
        XCTAssertEqual(world.snapshot.foods.first?.kind, .berry)
        XCTAssertEqual(weighted.taste, raw.taste)
        XCTAssertEqual(weighted.loomingLeft, raw.loomingLeft)
        XCTAssertEqual(weighted.loomingRight, raw.loomingRight)
        XCTAssertEqual(weighted.touch, raw.touch)
    }

    func testCalibrationClearsPriorNeuralObservationButKeepsBodyAndMemory() {
        var world = PopulationWorld()
        let id = world.selectedIndividualID
        _ = world.advance(id, neural: NeuralReadout(forwardHz: 80),
                          input: world.neuralInput(id), dt: 0.1)
        let body = world.snapshot.body
        XCTAssertGreaterThan(world.snapshot.neural.forwardHz, 0)

        world.calibrate(BrainCalibration(baseline: NeuralReadout(forwardHz: 2)), for: id)
        XCTAssertEqual(world.snapshot.neural, NeuralReadout())
        XCTAssertEqual(world.snapshot.motor, MotorCommand())
        XCTAssertEqual(world.snapshot.body, body)
    }

    func testLearningControlsApplyOnlyToSelectedIndividual() {
        var trained = FlyMemory()
        trained.advance(seconds: 1,
                        cues: FoodCueObservation(banana: BilateralFoodCue(left: 1, right: 1)),
                        outcome: MemoryOutcome(bananaConsumed: 1))
        let firstID = UUID()
        let secondID = UUID()
        var world = PopulationWorld(profiles: [
            IndividualProfile(id: firstID, ordinal: 0, seed: 42),
            IndividualProfile(id: secondID, ordinal: 1, seed: 104729, memory: trained)
        ])

        world.perform(.toggleLearning)
        XCTAssertFalse(world.snapshot.individuals.first { $0.id == firstID }!.memory.learningEnabled)
        XCTAssertTrue(world.snapshot.individuals.first { $0.id == secondID }!.memory.learningEnabled)

        world.perform(.clearMemory)
        XCTAssertEqual(world.snapshot.individuals.first { $0.id == firstID }!.memory.stats.bananaValue, 0)
        XCTAssertGreaterThan(world.snapshot.individuals.first { $0.id == secondID }!.memory.stats.bananaValue, 0)

        world.selectIndividual(secondID)
        world.perform(.toggleLearning)
        XCTAssertFalse(world.snapshot.individuals.first { $0.id == secondID }!.memory.learningEnabled)
        XCTAssertFalse(world.snapshot.individuals.first { $0.id == firstID }!.memory.learningEnabled)
    }
}
