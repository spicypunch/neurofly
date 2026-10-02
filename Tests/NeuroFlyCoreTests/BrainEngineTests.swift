import XCTest
@testable import NeuroFlyCore

final class BrainEngineTests: XCTestCase {
    private func dataDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NeuroFlyCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // project root
            .appendingPathComponent("data", isDirectory: true)
    }

    func testLoadsRealGraphAndPublishesExactMapping() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        XCTAssertEqual(brain.neuronCount, 139_255)
        XCTAssertEqual(brain.edgeCount, 15_091_983)
        XCTAssertFalse(brain.gpuName.isEmpty)
        XCTAssertTrue(brain.mappingSummary["taste"]?.contains("20") == true)
        XCTAssertTrue(brain.mappingSummary["odorLeft"]?.contains("ORN_DM1") == true)
        XCTAssertTrue(brain.mappingSummary["feeding"]?.contains("CB0701") == true)
    }

    func testResetReplaysTheSameDeterministicTrace() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        let first = try brain.advance(milliseconds: 100,
                                      input: SensoryInput(odorLeft: 1, taste: 1))
        try brain.reset(seed: 42)
        let second = try brain.advance(milliseconds: 100,
                                       input: SensoryInput(odorLeft: 1, taste: 1))
        var expected = first
        var actual = second
        expected.computationMilliseconds = 0
        actual.computationMilliseconds = 0
        XCTAssertEqual(expected, actual)
    }

    func testTasteDrivesPublishedFeedingReadoutThroughTheGraph() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        let baseline = try response(brain, input: SensoryInput())
        let taste = try response(brain, input: SensoryInput(taste: 1))
        XCTAssertGreaterThan(taste.feedingHz, baseline.feedingHz + 8)
    }

    func testOdorDrivesBothDM1RelayReadoutsWithoutChoosingASteeringSign() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        _ = try brain.advance(milliseconds: 500, input: SensoryInput())
        let odor = try brain.advance(milliseconds: 500, input: SensoryInput(odorLeft: 1))
        XCTAssertGreaterThan(odor.odorRelayLeftHz, 0)
        XCTAssertGreaterThan(odor.odorRelayRightHz, 0)
    }

    func testSensoryDisabledRemovesExternalOdorDrive() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        let baseline = try response(brain, input: SensoryInput())
        let blocked = try response(brain, input: SensoryInput(odorLeft: 1, odorRight: 1,
            taste: 1, loomingLeft: 1, loomingRight: 1, touch: 1), enabled: false)
        XCTAssertEqual(blocked, baseline, "Every neural readout must match the same-time unstimulated control")
    }

    func testVisualAndTouchStimuliDriveEscapeThroughTheGraph() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        let baseline = try response(brain, input: SensoryInput())
        for stimulus in [SensoryInput(loomingLeft: 1, loomingRight: 1), SensoryInput(touch: 1)] {
            let stimulated = try response(brain, input: stimulus)
            XCTAssertGreaterThan(stimulated.escapeHz, baseline.escapeHz + 10)
            var decoder = MotorDecoder()
            decoder.calibrate(baseline)
            XCTAssertEqual(decoder.decode(stimulated, dt: 0.033).activity, .escaping)
        }
    }

    func testNegativeAdvanceIsReported() throws {
        let brain = try BrainEngine(dataDirectory: dataDirectory(), seed: 42)
        XCTAssertThrowsError(try brain.advance(milliseconds: -1, input: SensoryInput()))
    }

    private func response(_ brain: BrainEngine, input: SensoryInput, enabled: Bool = true) throws -> NeuralReadout {
        try brain.reset(seed: 42)
        _ = try brain.advance(milliseconds: 500, input: SensoryInput())
        var result = try brain.advance(milliseconds: 500, input: input, sensoryEnabled: enabled)
        result.computationMilliseconds = 0
        return result
    }
}
