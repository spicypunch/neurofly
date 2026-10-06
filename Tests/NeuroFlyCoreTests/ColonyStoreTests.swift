import XCTest
@testable import NeuroFlyCore

final class ColonyStoreTests: XCTestCase {
    private func withStore(_ body: (ColonyStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neurofly-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ColonyStore(url: directory.appendingPathComponent("colony.json")))
    }

    func testMissingStoreThenRoundTripKeepsIndividualsAndModel() throws {
        try withStore { store in
            XCTAssertNil(try store.load())
            var population = PopulationWorld()
            population.perform(.addIndividual)
            let selected = population.individualIDs[1]
            let archive = ColonyArchive(brainModel: .maleCNS, selectedIndividualID: selected,
                                        profiles: population.profiles)
            try store.save(archive)
            XCTAssertEqual(try store.load(), archive)
        }
    }

    func testInvalidReplacementDoesNotDestroyExistingArchive() throws {
        try withStore { store in
            let population = PopulationWorld()
            var archive = ColonyArchive(brainModel: .flywireV783,
                                        selectedIndividualID: population.selectedIndividualID,
                                        profiles: population.profiles)
            try store.save(archive)
            let original = try Data(contentsOf: store.url)
            archive.profiles.append(archive.profiles[0])
            XCTAssertThrowsError(try store.save(archive))
            XCTAssertEqual(try Data(contentsOf: store.url), original)
        }
    }

    func testLearnedPreferenceSurvivesDiskAndPopulationRecreationPerIndividual() throws {
        try withStore { store in
            var population = PopulationWorld()
            population.perform(.addIndividual)
            var profiles = population.profiles
            var memory = FlyMemory()
            for _ in 0..<120 {
                memory.advance(seconds: 1.0 / 30,
                    cues: FoodCueObservation(berry: BilateralFoodCue(left: 0.8, right: 0.6)),
                    outcome: MemoryOutcome(berryConsumed: 0.005))
            }
            profiles[1].memory = memory.memoryForPersistence
            let archive = ColonyArchive(brainModel: .flywireV783,
                                        selectedIndividualID: profiles[1].id, profiles: profiles)
            try store.save(archive)
            let restored = try XCTUnwrap(store.load())
            let restarted = PopulationWorld(profiles: restored.profiles)
            XCTAssertEqual(restarted.snapshot.individuals[0].memory.gain(for: .berry), 1)
            XCTAssertGreaterThan(restarted.snapshot.individuals[1].memory.gain(for: .berry), 1)
            XCTAssertEqual(restarted.snapshot.individuals[1].memory.gain(for: .berry),
                           memory.gain(for: .berry))
            XCTAssertEqual(restarted.snapshot.individuals[1].body.consumedFood, 0,
                           "A new body must not pretend to replay the saved meal")
            XCTAssertTrue(restarted.snapshot.foods.isEmpty)
        }
    }

    func testCorruptAndFutureVersionArchivesArePreservedForRecovery() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let corrupt = Data("not-json".utf8)
            try corrupt.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            let backup = try store.preserveUnreadableArchive()
            XCTAssertEqual(try Data(contentsOf: backup), corrupt)
            XCTAssertNil(try store.load())

            let population = PopulationWorld()
            var archive = ColonyArchive(brainModel: .flywireV783,
                                        selectedIndividualID: population.selectedIndividualID,
                                        profiles: population.profiles)
            archive.schemaVersion = 2
            try JSONEncoder().encode(archive).write(to: store.url)
            XCTAssertThrowsError(try store.load())
        }
    }
}
