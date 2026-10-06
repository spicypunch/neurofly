import Foundation

/// A durable identity and associative-memory checkpoint. Membrane voltages,
/// food locations and simulation clocks are intentionally not saved here.
public struct ColonyArchive: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var brainModel: BrainModel
    public var selectedIndividualID: UUID
    public var profiles: [IndividualProfile]

    public init(brainModel: BrainModel, selectedIndividualID: UUID,
                profiles: [IndividualProfile]) {
        self.brainModel = brainModel
        self.selectedIndividualID = selectedIndividualID
        self.profiles = profiles
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw BrainEngineError.invalidData("unsupported colony memory version \(schemaVersion)")
        }
        guard (1...PopulationWorld.maximumIndividuals).contains(profiles.count),
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.ordinal)).count == profiles.count,
              profiles.allSatisfy({ (0...1_000_000).contains($0.ordinal) }),
              profiles.contains(where: { $0.id == selectedIndividualID }) else {
            throw BrainEngineError.invalidData("invalid colony identities or selection")
        }
    }
}

/// One small JSON file, written atomically. Callers surface errors and never
/// replace an unreadable checkpoint with defaults without preserving it.
public struct ColonyStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ColonyArchive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 else {
            throw BrainEngineError.invalidData("colony memory file has an invalid size")
        }
        let archive = try JSONDecoder().decode(ColonyArchive.self, from: Data(contentsOf: url))
        try archive.validate()
        return archive
    }

    public func save(_ archive: ColonyArchive) throws {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Preserve a damaged file for recovery before creating a new checkpoint.
    @discardableResult
    public func preserveUnreadableArchive() throws -> URL {
        let backup = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
}
