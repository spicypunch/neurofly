import Foundation
import XCTest
@testable import NeuroFlyCore

final class FlyMemoryTests: XCTestCase {
    private let frame = 1.0 / 30.0

    private var bananaCue: FoodCueObservation {
        FoodCueObservation(banana: BilateralFoodCue(left: 0.7, right: 0.5))
    }

    private var berryCue: FoodCueObservation {
        FoodCueObservation(berry: BilateralFoodCue(left: 0.7, right: 0.5))
    }

    func testFoodKindsExposeStableVirtualIdentity() {
        XCTAssertEqual(FoodKind.allCases, [.banana, .berry])
        XCTAssertEqual(FoodKind.banana.displayName, "바나나")
        XCTAssertEqual(FoodKind.berry.displayName, "베리")

        let cues = FoodCueObservation(banana: BilateralFoodCue(left: 0.2, right: 0.3),
                                      berry: BilateralFoodCue(left: 0.4, right: 0.1),
                                      threat: 0.5)
        XCTAssertEqual(cues[.banana], cues.banana)
        XCTAssertEqual(cues[.berry], cues.berry)
    }

    func testUntrainedMemoryHasExactNeutralGainAndPreservesRawNonOdorChannels() {
        let memory = FlyMemory()
        let raw = SensoryInput(odorLeft: 0.42, odorRight: 0.31, taste: 0.6,
                               loomingLeft: 0.2, loomingRight: 0.4, touch: 1)
        let weighted = memory.weightedSensoryInput(raw: raw, cues: bananaCue)

        XCTAssertEqual(memory.gain(for: .banana), 1)
        XCTAssertEqual(memory.gain(for: .berry), 1)
        XCTAssertEqual(weighted, raw)
        XCTAssertEqual(memory.stats.learnedFood, 0)
        XCTAssertEqual(memory.stats.rewardedIntake, 0, accuracy: 1e-12)
    }

    func testActualConsumptionLearnsOnlyTheConsumedFoodCue() {
        var memory = FlyMemory()
        for _ in 0..<90 {
            memory.advance(seconds: frame, cues: bananaCue,
                           outcome: MemoryOutcome(bananaConsumed: 0.01))
        }

        XCTAssertGreaterThan(memory.gain(for: .banana), 1)
        XCTAssertEqual(memory.gain(for: .berry), 1)
        XCTAssertEqual(memory.stats.learnedFood, 1,
                       "A continuous meal must count as one food episode")
        XCTAssertEqual(memory.stats.rewardedIntake, 0.9, accuracy: 1e-12)
    }

    func testTasteOrOdorWithoutActualIntakeDoesNotCreateFoodReward() {
        var memory = FlyMemory()
        let cueWithTaste = FoodCueObservation(banana: BilateralFoodCue(left: 1, right: 1))
        for _ in 0..<180 {
            memory.advance(seconds: frame, cues: cueWithTaste,
                           outcome: MemoryOutcome())
        }

        XCTAssertEqual(memory.value(for: .banana), 0, accuracy: 1e-12)
        XCTAssertEqual(memory.gain(for: .banana), 1)
        XCTAssertEqual(memory.stats.learnedFood, 0)
        XCTAssertEqual(memory.stats.rewardedIntake, 0, accuracy: 1e-12)
    }

    func testThreatPairedWithRecentCueLearnsMoreThanDelayedThreat() {
        var paired = FlyMemory()
        for _ in 0..<60 {
            paired.advance(seconds: frame, cues: bananaCue,
                           outcome: MemoryOutcome(threat: 1))
        }

        var delayed = FlyMemory()
        for _ in 0..<60 {
            delayed.advance(seconds: frame, cues: bananaCue, outcome: MemoryOutcome())
        }
        for _ in 0..<300 {
            delayed.advance(seconds: frame, cues: FoodCueObservation(), outcome: MemoryOutcome())
        }
        for _ in 0..<60 {
            delayed.advance(seconds: frame, cues: FoodCueObservation(),
                            outcome: MemoryOutcome(threat: 1))
        }

        XCTAssertLessThan(paired.gain(for: .banana), delayed.gain(for: .banana))
        XCTAssertEqual(paired.stats.threatAssociations, 1)
        XCTAssertEqual(delayed.stats.threatAssociations, 0)
    }

    func testPositiveLearningCanBeReversedAndThenForgotten() {
        var memory = FlyMemory()
        for _ in 0..<90 {
            memory.advance(seconds: frame, cues: bananaCue,
                           outcome: MemoryOutcome(bananaConsumed: 0.01))
        }
        let positiveGain = memory.gain(for: .banana)

        for _ in 0..<90 {
            memory.advance(seconds: frame, cues: bananaCue,
                           outcome: MemoryOutcome(threat: 1))
        }
        let reversedGain = memory.gain(for: .banana)
        XCTAssertLessThan(reversedGain, positiveGain)
        XCTAssertEqual(memory.stats.threatAssociations, 1)

        memory.advance(seconds: FlyMemory.forgettingTimeConstant * 5,
                       cues: FoodCueObservation(), outcome: MemoryOutcome())
        let forgottenGain = memory.gain(for: .banana)
        XCTAssertEqual(forgottenGain, 1, accuracy: 0.01)
        XCTAssertLessThan(abs(Double(forgottenGain) - 1), abs(Double(reversedGain) - 1))
    }

    func testMixedSaturatedCueRecombinesCategorizedOdorsBeforeClamping() {
        var memory = FlyMemory()
        for _ in 0..<600 {
            memory.advance(seconds: frame, cues: bananaCue,
                           outcome: MemoryOutcome(threat: 1))
        }
        XCTAssertEqual(memory.gain(for: .banana), FlyMemory.minimumGain, accuracy: 1e-6)

        let raw = SensoryInput(odorLeft: 1, odorRight: 1, taste: 0.4,
                               loomingLeft: 0.2, loomingRight: 0.3, touch: 0.1)
        let cues = FoodCueObservation(
            banana: BilateralFoodCue(left: 1, right: 1),
            berry: BilateralFoodCue(left: 1, right: 1))
        let weighted = memory.weightedSensoryInput(raw: raw, cues: cues)

        XCTAssertEqual(weighted.odorLeft, 1, accuracy: 1e-6)
        XCTAssertEqual(weighted.odorRight, 1, accuracy: 1e-6)
        XCTAssertEqual(weighted.taste, raw.taste)
        XCTAssertEqual(weighted.loomingLeft, raw.loomingLeft)
        XCTAssertEqual(weighted.loomingRight, raw.loomingRight)
        XCTAssertEqual(weighted.touch, raw.touch)
    }

    func testDisabledMemoryIsNeutralAndDoesNotLeakEligibilityWhenReenabled() {
        var memory = FlyMemory(learningEnabled: false)
        for _ in 0..<120 {
            memory.advance(seconds: frame, cues: bananaCue,
                           outcome: MemoryOutcome(bananaConsumed: 1, threat: 1))
        }
        XCTAssertEqual(memory.gain(for: .banana), 1)
        XCTAssertEqual(memory.gain(for: .berry), 1)

        memory.learningEnabled = true
        memory.advance(seconds: frame, cues: FoodCueObservation(),
                        outcome: MemoryOutcome(bananaConsumed: 0.01))
        XCTAssertEqual(memory.gain(for: .banana), 1,
                       "Disabled periods must not leave an eligibility trace behind")
    }

    func testInvalidInputsRemainFiniteAndGainStaysBounded() {
        var memory = FlyMemory()
        memory.advance(seconds: .nan,
                       cues: FoodCueObservation(banana: BilateralFoodCue(left: .infinity, right: .nan),
                                                threat: .infinity),
                       outcome: MemoryOutcome(bananaConsumed: .infinity,
                                              berryConsumed: .nan, threat: -.infinity))
        memory.advance(seconds: .infinity, cues: bananaCue,
                       outcome: MemoryOutcome(bananaConsumed: 1))
        memory.advance(seconds: -1, cues: bananaCue,
                       outcome: MemoryOutcome(bananaConsumed: 1))

        XCTAssertEqual(memory.gain(for: .banana), 1)
        XCTAssertEqual(memory.stats.learnedFood, 0)
        XCTAssertTrue(memory.stats.bananaValue.isFinite)
        XCTAssertTrue(memory.stats.berryValue.isFinite)
        XCTAssertTrue(memory.stats.rewardedIntake.isFinite)
        XCTAssertGreaterThanOrEqual(memory.gain(for: .banana), FlyMemory.minimumGain)
        XCTAssertLessThanOrEqual(memory.gain(for: .banana), FlyMemory.maximumGain)
    }

    func testThirtyAndSixtyHertzLearningStayCloseForTheSameContinuousExperience() {
        var thirtyHertz = FlyMemory()
        var sixtyHertz = FlyMemory()
        let totalFood = 0.3

        for _ in 0..<360 {
            thirtyHertz.advance(seconds: 1.0 / 30, cues: bananaCue,
                                outcome: MemoryOutcome(bananaConsumed: totalFood / 360))
        }
        for _ in 0..<720 {
            sixtyHertz.advance(seconds: 1.0 / 60, cues: bananaCue,
                               outcome: MemoryOutcome(bananaConsumed: totalFood / 720))
        }

        XCTAssertEqual(thirtyHertz.value(for: .banana), sixtyHertz.value(for: .banana), accuracy: 0.002)
        XCTAssertEqual(thirtyHertz.gain(for: .banana), sixtyHertz.gain(for: .banana), accuracy: 0.002)
        XCTAssertEqual(thirtyHertz.stats.rewardedIntake, totalFood, accuracy: 1e-12)
        XCTAssertEqual(sixtyHertz.stats.rewardedIntake, totalFood, accuracy: 1e-12)
    }

    func testThirtyAndSixtyHertzThreatLearningStayClose() {
        var thirtyHertz = FlyMemory()
        var sixtyHertz = FlyMemory()
        let duration = 12.0

        for _ in 0..<Int(duration * 30) {
            thirtyHertz.advance(seconds: 1.0 / 30, cues: bananaCue,
                                outcome: MemoryOutcome(threat: 1))
        }
        for _ in 0..<Int(duration * 60) {
            sixtyHertz.advance(seconds: 1.0 / 60, cues: bananaCue,
                               outcome: MemoryOutcome(threat: 1))
        }

        XCTAssertEqual(thirtyHertz.value(for: .banana), sixtyHertz.value(for: .banana), accuracy: 0.002)
        XCTAssertEqual(thirtyHertz.gain(for: .banana), sixtyHertz.gain(for: .banana), accuracy: 0.002)
        XCTAssertEqual(thirtyHertz.stats.threatAssociations, 1)
        XCTAssertEqual(sixtyHertz.stats.threatAssociations, 1)
    }

    func testCodableCheckpointKeepsLearnedValuesButClearsEligibilityTrace() throws {
        var memory = FlyMemory()
        memory.advance(seconds: frame, cues: bananaCue, outcome: MemoryOutcome())
        let checkpoint = memory.memoryForPersistence
        let data = try JSONEncoder().encode(checkpoint)
        let restored = try JSONDecoder().decode(FlyMemory.self, from: data)

        XCTAssertEqual(restored, checkpoint)
        XCTAssertEqual(restored.gain(for: .banana), checkpoint.gain(for: .banana))

        var live = memory
        live.advance(seconds: frame, cues: FoodCueObservation(),
                     outcome: MemoryOutcome(bananaConsumed: 0.01))
        var resumed = restored
        resumed.advance(seconds: frame, cues: FoodCueObservation(),
                        outcome: MemoryOutcome(bananaConsumed: 0.01))
        XCTAssertGreaterThan(live.value(for: .banana), resumed.value(for: .banana))
    }

    func testCodableRejectsUnknownSchemaVersion() throws {
        let data = try JSONEncoder().encode(FlyMemory())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 999
        let unknownVersion = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(FlyMemory.self, from: unknownVersion))
    }

    func testResetReturnsToFreshNeutralMemory() {
        var memory = FlyMemory()
        for _ in 0..<90 {
            memory.advance(seconds: frame, cues: berryCue,
                           outcome: MemoryOutcome(berryConsumed: 0.01))
        }
        memory.reset()

        XCTAssertEqual(memory.gain(for: .banana), 1)
        XCTAssertEqual(memory.gain(for: .berry), 1)
        XCTAssertEqual(memory.stats.learnedFood, 0)
        XCTAssertEqual(memory.stats.rewardedIntake, 0, accuracy: 1e-12)
        XCTAssertEqual(memory.stats.threatAssociations, 0)
    }
}
