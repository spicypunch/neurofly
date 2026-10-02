import XCTest
@testable import NeuroFlyCore

final class BodyStateTests: XCTestCase {
    func testDefaultBodyStartsFoodMotivated() {
        let body = BodyState()

        XCTAssertEqual(body.hunger, 0.65, accuracy: 1e-12)
        XCTAssertTrue(body.isFoodMotivated)
        XCTAssertEqual(body.foodDrive, 1)
        XCTAssertEqual(body.consumedFood, 0, accuracy: 1e-12)
    }

    func testTimeRaisesHungerAndSpeedAddsMetabolicCost() {
        var resting = BodyState(hunger: 0.1)
        resting.advance(seconds: 10, speed: 0, foodConsumed: 0)
        XCTAssertEqual(resting.hunger, 0.12, accuracy: 1e-12)

        var flying = BodyState(hunger: 0.1)
        flying.advance(seconds: 10, speed: 120, foodConsumed: 0)
        XCTAssertEqual(flying.hunger, 0.125, accuracy: 1e-12)
    }

    func testEatingReducesHungerAndAccumulatesConsumedFood() {
        var body = BodyState(hunger: 0.65)
        body.advance(seconds: 2, speed: 0, foodConsumed: 0.1)

        XCTAssertEqual(body.hunger, 0.534, accuracy: 1e-12)
        XCTAssertEqual(body.consumedFood, 0.1, accuracy: 1e-12)
        XCTAssertTrue(body.isFoodMotivated, "The middle hysteresis band must preserve motivation")
    }

    func testMotivationUsesHysteresis() {
        var body = BodyState(hunger: 0.19)
        XCTAssertFalse(body.isFoodMotivated)

        body.advance(seconds: 100, speed: 0, foodConsumed: 0)
        XCTAssertEqual(body.hunger, 0.39, accuracy: 1e-12)
        XCTAssertFalse(body.isFoodMotivated, "The middle band must not turn motivation on")

        body.advance(seconds: 110, speed: 0, foodConsumed: 0)
        XCTAssertEqual(body.hunger, 0.61, accuracy: 1e-12)
        XCTAssertTrue(body.isFoodMotivated)

        body.advance(seconds: 1, speed: 0, foodConsumed: 0.35)
        XCTAssertLessThanOrEqual(body.hunger, BodyState.motivationOffThreshold)
        XCTAssertFalse(body.isFoodMotivated)
    }

    func testHungerAndInvalidInputsStayBounded() {
        var low = BodyState(hunger: -10)
        let high = BodyState(hunger: 10)
        XCTAssertEqual(low.hunger, 0)
        XCTAssertFalse(low.isFoodMotivated)
        XCTAssertEqual(high.hunger, 1)
        XCTAssertTrue(high.isFoodMotivated)

        low.advance(seconds: .nan, speed: 120, foodConsumed: 1)
        low.advance(seconds: .infinity, speed: 120, foodConsumed: 1)
        low.advance(seconds: -1, speed: 120, foodConsumed: 1)
        XCTAssertEqual(low.hunger, 0)
        XCTAssertEqual(low.consumedFood, 0)

        var body = BodyState(hunger: 0.5)
        body.advance(seconds: 1, speed: -.infinity, foodConsumed: -.nan)
        XCTAssertEqual(body.hunger, 0.502, accuracy: 1e-12)
        XCTAssertEqual(body.consumedFood, 0)
        XCTAssertTrue(body.hunger.isFinite)
        XCTAssertTrue(body.consumedFood.isFinite)
        XCTAssertGreaterThanOrEqual(body.hunger, 0)
        XCTAssertLessThanOrEqual(body.hunger, 1)
    }

    func testEquivalentThirtyAndSixtyHertzStepsMatch() {
        var thirtyHertz = BodyState(hunger: 0.4)
        var sixtyHertz = BodyState(hunger: 0.4)
        let totalFood = 0.24

        for _ in 0..<360 {
            thirtyHertz.advance(seconds: 1.0 / 30, speed: 30, foodConsumed: totalFood / 360)
        }
        for _ in 0..<720 {
            sixtyHertz.advance(seconds: 1.0 / 60, speed: 30, foodConsumed: totalFood / 720)
        }

        XCTAssertEqual(thirtyHertz.hunger, sixtyHertz.hunger, accuracy: 1e-12)
        XCTAssertEqual(thirtyHertz.consumedFood, totalFood, accuracy: 1e-12)
        XCTAssertEqual(sixtyHertz.consumedFood, totalFood, accuracy: 1e-12)
        XCTAssertEqual(thirtyHertz.isFoodMotivated, sixtyHertz.isFoodMotivated)
    }
}
