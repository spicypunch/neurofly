import XCTest
@testable import NeuroFlyCore

final class WorldTests: XCTestCase {
    func testFoodAloneCannotMoveBodyOrBeConsumed() {
        var world = SimulationWorld()
        let original = world.snapshot.fly.position
        world.perform(.placeFood(Point2(x: original.x + 18, y: original.y)))
        XCTAssertEqual(world.sense().taste, 1)
        for _ in 0..<60 { world.advance(neural: NeuralReadout(), input: world.sense(), dt: 1.0 / 30) }
        XCTAssertEqual(world.snapshot.fly.position, original)
        XCTAssertEqual(world.snapshot.foods[0].remaining, 1)
    }

    func testMeasuredMotorActivityMovesBodyAndEscapeOverridesFeeding() {
        var world = SimulationWorld()
        let initial = world.snapshot.fly.position
        world.advance(neural: NeuralReadout(forwardHz: 15), input: SensoryInput(), dt: 0.05)
        XCTAssertGreaterThan(world.snapshot.fly.position.x, initial.x)
        XCTAssertEqual(world.snapshot.fly.activity, .flying)
        world.advance(neural: NeuralReadout(escapeHz: 30, feedingHz: 20), input: SensoryInput(), dt: 0.05)
        XCTAssertEqual(world.snapshot.fly.activity, .escaping)
    }

    func testNeuralFeedingResponseConsumesContactFood() {
        var world = SimulationWorld()
        let initial = world.snapshot.fly.position
        world.perform(.placeFood(Point2(x: initial.x + 18, y: initial.y)))
        world.advance(neural: NeuralReadout(feedingHz: 30), input: world.sense(), dt: 0.05)
        XCTAssertEqual(world.snapshot.fly.activity, .feeding)
        XCTAssertLessThan(world.snapshot.foods[0].remaining, 1)
    }

    func testIdenticalMotorStreamIgnoresFoodPositions() {
        var left = SimulationWorld(), right = SimulationWorld()
        left.perform(.placeFood(Point2(x: 100, y: 100)))
        right.perform(.placeFood(Point2(x: 800, y: 500)))
        let motor = MotorCommand(speed: 45, turnRate: 0.3, activity: .flying)
        for _ in 0..<100 { left.advanceBody(motor: motor, dt: 0.02); right.advanceBody(motor: motor, dt: 0.02) }
        XCTAssertEqual(left.snapshot.fly, right.snapshot.fly)
    }

    func testIdenticalNeuralStreamCannotSteerTowardDifferentFoodCoordinates() {
        var left = SimulationWorld(), right = SimulationWorld()
        left.perform(.placeFood(Point2(x: 100, y: 100)))
        right.perform(.placeFood(Point2(x: 800, y: 500)))
        let neural = NeuralReadout(turnLeftHz: 22, turnRightHz: 10, forwardHz: 15,
                                  odorRelayLeftHz: 150, odorRelayRightHz: 120)
        for _ in 0..<100 {
            left.advance(neural: neural, input: left.sense(), dt: 0.02)
            right.advance(neural: neural, input: right.sense(), dt: 0.02)
        }
        XCTAssertEqual(left.snapshot.fly, right.snapshot.fly)
    }

    func testSmellPrecedesContactAndGateCutsAllInputs() {
        var world = SimulationWorld()
        let fly = world.snapshot.fly.position
        world.perform(.placeFood(Point2(x: fly.x + 100, y: fly.y + 50)))
        XCTAssertGreaterThan(world.sense().odorLeft, world.sense().odorRight)
        XCTAssertEqual(world.sense().taste, 0)
        world.perform(.castShadow(fly)); world.perform(.touchFly)
        world.perform(.toggleSensory)
        XCTAssertEqual(world.sense(), SensoryInput())
    }

    func testFeedingNeedsBothNeuralCommandAndPhysicalContact() {
        var world = SimulationWorld()
        let fly = world.snapshot.fly.position
        world.perform(.placeFood(Point2(x: fly.x + 18, y: fly.y)))
        world.perform(.placeFood(Point2(x: 50, y: 50)))
        world.advanceBody(motor: MotorCommand(activity: .feeding), dt: 0.1)
        XCTAssertLessThan(world.snapshot.foods[0].remaining, 1)
        XCTAssertEqual(world.snapshot.foods[1].remaining, 1)
    }

    func testPauseFreezesWorldAndTransientStimuli() {
        var world = SimulationWorld()
        world.perform(.touchFly); world.perform(.togglePause)
        let before = world.snapshot.fly
        world.advance(neural: NeuralReadout(forwardHz: 50), input: world.sense(), dt: 0.05)
        XCTAssertEqual(world.snapshot.fly, before)
        XCTAssertEqual(world.snapshot.elapsed, 0)
        XCTAssertEqual(world.sense().touch, 1)
    }

    func testInvalidCoordinatesAndResizeCannotCorruptWorld() {
        var world = SimulationWorld()
        world.perform(.placeFood(Point2(x: .nan, y: .infinity)))
        world.resize(width: .nan, height: 100)
        XCTAssertEqual(world.snapshot.foods.count, 0)
        XCTAssertTrue(world.snapshot.width.isFinite)
    }

    func testFallingRelayActivityStartsBoundedSearchAndCalibrationClearsIt() {
        let calibration = BrainCalibration(odorBalance: [.init(totalHz: 200, leftFraction: 0.5)])
        var decoder = MotorDecoder()
        decoder.calibrate(calibration)
        let strong = NeuralReadout(forwardHz: 20, odorRelayLeftHz: 200, odorRelayRightHz: 200)
        let weaker = NeuralReadout(forwardHz: 20, odorRelayLeftHz: 70, odorRelayRightHz: 70)
        for _ in 0..<90 { _ = decoder.decode(strong, dt: 1.0 / 30) }
        var search = MotorCommand()
        for _ in 0..<15 { search = decoder.decode(weaker, dt: 1.0 / 30) }
        XCTAssertEqual(search.activity, .flying)
        XCTAssertGreaterThan(search.speed, 0)
        XCTAssertGreaterThan(abs(search.turnRate), 0.5)
        XCTAssertLessThanOrEqual(abs(search.turnRate), 2.8)

        decoder.calibrate(calibration)
        var fresh = MotorDecoder()
        fresh.calibrate(calibration)
        for _ in 0..<60 {
            XCTAssertEqual(decoder.decode(weaker, dt: 1.0 / 30), fresh.decode(weaker, dt: 1.0 / 30))
        }
    }

    func testFeedingInterruptsSearchAndZeroNeuralInputCannotDriveSearch() {
        let calibration = BrainCalibration(odorBalance: [.init(totalHz: 200, leftFraction: 0.5)])
        var decoder = MotorDecoder()
        decoder.calibrate(calibration)
        for _ in 0..<90 {
            _ = decoder.decode(NeuralReadout(forwardHz: 20, odorRelayLeftHz: 200, odorRelayRightHz: 200), dt: 1.0 / 30)
        }
        for _ in 0..<15 {
            _ = decoder.decode(NeuralReadout(forwardHz: 20, odorRelayLeftHz: 70, odorRelayRightHz: 70), dt: 1.0 / 30)
        }
        let feeding = decoder.decode(NeuralReadout(forwardHz: 20, feedingHz: 50,
            odorRelayLeftHz: 70, odorRelayRightHz: 70), dt: 1.0 / 30)
        XCTAssertEqual(feeding, MotorCommand(activity: .feeding))
        decoder.calibrate(calibration)
        for _ in 0..<300 { XCTAssertEqual(decoder.decode(NeuralReadout(), dt: 1.0 / 30), MotorCommand()) }
    }
}
