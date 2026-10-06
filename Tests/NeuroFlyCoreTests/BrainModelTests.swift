import XCTest
@testable import NeuroFlyCore

final class BrainModelTests: XCTestCase {
    private let fixtureRootIDs = (1...16).map(UInt64.init)

    func testModelIdentifiersAndDataLocationsAreStable() {
        XCTAssertEqual(BrainModel.flywireV783.rawValue, "flywire-v783")
        XCTAssertEqual(BrainModel.maleCNS.rawValue, "malecns")
        XCTAssertEqual(BrainModel.flywireV783.displayName, "FlyWire v783")
        XCTAssertEqual(BrainModel.maleCNS.displayName, "Male CNS")
        XCTAssertEqual(BrainModel.flywireV783.dataSubdirectory, "")
        XCTAssertEqual(BrainModel.maleCNS.dataSubdirectory, "malecns")
        XCTAssertEqual(Set(BrainModel.allCases), [.flywireV783, .maleCNS])
    }

    func testFixedPointScaleUsesPerTargetIncomingBound() throws {
        // A target with thousands of modest incoming edges is exactly the
        // case the previous max-edge * 4096 heuristic missed.  Check both
        // polarities because Metal accumulates excitation and inhibition in
        // separate Int32 atomics.
        let scale = try MetalBrainSimulation.chooseFixedPointScale(
            positiveIncoming: [10_000],
            negativeIncoming: [20_000],
            positiveCounts: [5_000],
            negativeCounts: [7_000])

        XCTAssertEqual(scale, 65_536)
        let bound = 20_000 * Double(scale) + 7_000
        XCTAssertLessThanOrEqual(bound, Double(Int32.max))
        XCTAssertGreaterThan(20_000 * Double(scale * 2) + 7_000,
                             Double(Int32.max))
    }

    func testLegacyCalibrationKeepsMeasuredFeedingThresholdOptional() throws {
        let legacy = BrainCalibration()
        XCTAssertNil(legacy.feedingThresholdHz)

        let measured = BrainCalibration(
            feedingOdorOnlyHz: 9.2,
            feedingTasteAndOdorHz: 25.9,
            feedingThresholdHz: 17.55)
        let data = try JSONEncoder().encode(measured)
        let restored = try JSONDecoder().decode(BrainCalibration.self, from: data)
        XCTAssertEqual(restored.feedingOdorOnlyHz, 9.2)
        XCTAssertEqual(restored.feedingTasteAndOdorHz, 25.9)
        XCTAssertEqual(restored.feedingThresholdHz, 17.55)
    }

    func testMeasuredFeedingThresholdSeparatesNonFeedingAndTasteSignals() {
        let calibration = BrainCalibration(
            baseline: NeuralReadout(feedingHz: 12),
            feedingOdorOnlyHz: 7,
            feedingTasteAndOdorHz: 30,
            feedingThresholdHz: 21)
        var decoder = MotorDecoder()
        decoder.calibrate(calibration)

        let odorOnly = decoder.decode(NeuralReadout(feedingHz: 12), dt: 1.0 / 30)
        let taste = decoder.decode(NeuralReadout(feedingHz: 30), dt: 1.0 / 30)
        XCTAssertNotEqual(odorOnly.activity, .feeding)
        XCTAssertEqual(taste.activity, .feeding)
    }

    func testLegacyGraphPublishesItsSelectedModelMetadata() throws {
        let dataDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("data", isDirectory: true)
        let brain = try BrainEngine(dataDirectory: dataDirectory, seed: 42)

        XCTAssertEqual(brain.model, .flywireV783)
        XCTAssertEqual(brain.modelID, "flywire-v783")
        XCTAssertEqual(brain.modelName, "FlyWire v783")
        XCTAssertEqual(brain.mappingSummary["dataset"], "FlyWire v783 [flywire-v783]")
    }

    func testManifestMappingAcceptsCompleteDisjointGroups() throws {
        let mapping = makeMapping()
        let validated = try validateNeuralMapping(mapping,
                                                  rootIDs: fixtureRootIDs,
                                                  model: .maleCNS)

        XCTAssertEqual(validated.odorLeft, [0])
        XCTAssertEqual(validated.odorRight, [1])
        XCTAssertEqual(validated.taste, [4])
        XCTAssertEqual(validated.turnLeft, [8])
        XCTAssertEqual(validated.flightRight, [15])
    }

    func testManifestMappingRejectsMissingAndEmptyGroups() {
        let missing = makeMapping(missing: ["taste"])
        assertInvalid(try validateNeuralMapping(missing,
                                                rootIDs: fixtureRootIDs,
                                                model: .maleCNS),
                      containing: "missing")

        let empty = makeMapping(overrides: ["taste": []])
        assertInvalid(try validateNeuralMapping(empty,
                                                rootIDs: fixtureRootIDs,
                                                model: .maleCNS),
                      containing: "empty")
    }

    func testManifestMappingRejectsUnknownDuplicateAndInputOutputOverlap() {
        let unknown = makeMapping(overrides: ["taste": [999]])
        assertInvalid(try validateNeuralMapping(unknown,
                                                rootIDs: fixtureRootIDs,
                                                model: .maleCNS),
                      containing: "unknown root ID")

        let duplicate = makeMapping(overrides: ["taste": [5, 5]])
        assertInvalid(try validateNeuralMapping(duplicate,
                                                rootIDs: fixtureRootIDs,
                                                model: .maleCNS),
                      containing: "duplicate root ID")

        // The same neuron cannot be an odor receptor and a direct turn
        // command. This is the provenance boundary that keeps external input
        // from bypassing the graph to drive a motor readout.
        let overlap = makeMapping(overrides: ["turnLeft": [1]])
        assertInvalid(try validateNeuralMapping(overlap,
                                                rootIDs: fixtureRootIDs,
                                                model: .maleCNS),
                      containing: "overlaps")
    }

    func testMaleCNSRejectsLegacyFallbackAndDatasetMismatch() {
        let directory = URL(fileURLWithPath: "/tmp/neurofly-test-data", isDirectory: true)
        let maleMetadata = ConnectomeManifest.DatasetMetadata(
            id: "malecns", displayName: "Male CNS", version: "test", source: "fixture")

        assertInvalid(try validateDatasetSelection(dataset: maleMetadata,
                                                   neuralMapping: nil,
                                                   model: .maleCNS,
                                                   selectedDirectory: directory),
                      containing: "requires an explicit neuralMapping")

        // A shared FlyWire data root must not become Male CNS merely because
        // someone added a partial mapping to its old manifest.
        assertInvalid(try validateDatasetSelection(dataset: nil,
                                                   neuralMapping: makeMapping(),
                                                   model: .maleCNS,
                                                   selectedDirectory: directory),
                      containing: "dataset.id")

        let flywireMetadata = ConnectomeManifest.DatasetMetadata(
            id: "malecns", displayName: "Male CNS", version: nil, source: nil)
        assertInvalid(try validateDatasetSelection(dataset: flywireMetadata,
                                                   neuralMapping: makeMapping(),
                                                   model: .flywireV783,
                                                   selectedDirectory: directory),
                      containing: "does not match selected model")
    }

    private func makeMapping(overrides: [String: [UInt64]] = [:],
                             missing: Set<String> = []) -> ConnectomeManifest.NeuralMapping {
        func value(_ name: String, _ defaultID: UInt64) -> [UInt64]? {
            if missing.contains(name) { return nil }
            return overrides[name] ?? [defaultID]
        }
        return ConnectomeManifest.NeuralMapping(
            odorLeft: value("odorLeft", 1), odorRight: value("odorRight", 2),
            odorRelayLeft: value("odorRelayLeft", 3), odorRelayRight: value("odorRelayRight", 4),
            taste: value("taste", 5), loomingLeft: value("loomingLeft", 6),
            loomingRight: value("loomingRight", 7), touch: value("touch", 8),
            turnLeft: value("turnLeft", 9), turnRight: value("turnRight", 10),
            forward: value("forward", 11), escape: value("escape", 12),
            feeding: value("feeding", 13), grooming: value("grooming", 14),
            flightLeft: value("flightLeft", 15), flightRight: value("flightRight", 16))
    }

    private func assertInvalid(_ expression: @autoclosure () throws -> Any,
                               containing: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertTrue(String(describing: error).contains(containing),
                          "Expected \(containing), got \(error)", file: file, line: line)
        }
    }
}
