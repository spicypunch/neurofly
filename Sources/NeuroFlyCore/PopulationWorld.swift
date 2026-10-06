import Foundation

/// Persistable identity for one population member.
///
/// Brain membrane state is deliberately not part of this profile. A profile
/// restores identity, deterministic seed, and the small associative memory
/// while a runtime creates a fresh connectome state and calibration.
public struct IndividualProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var ordinal: Int
    public var seed: UInt32
    public var memory: FlyMemory

    public init(id: UUID, ordinal: Int, seed: UInt32,
                memory: FlyMemory = FlyMemory()) {
        self.id = id
        self.ordinal = max(0, ordinal)
        self.seed = seed
        self.memory = memory.preparedForResume()
    }
}

/// A shared 2D environment with independent body, decoder, and transient
/// sensory state for each simulated individual.
///
/// The population layer intentionally does not own `BrainEngine` instances.
/// The app runtime owns one engine per profile and calls `sense`/`advance` for
/// each ID. This keeps the core world usable in deterministic tests and lets
/// the runtime choose whether to use independent engines or a future batched
/// graph backend.
public struct PopulationWorld: Sendable {
    public static let minimumIndividuals = 1
    public static let maximumIndividuals = 4

    private struct Agent: Sendable {
        var profile: IndividualProfile
        var world: SimulationWorld
    }

    public private(set) var snapshot = WorldSnapshot()

    private var agents: [Agent] = []
    private var selectedID: UUID
    private var width: Double
    private var height: Double
    private let initialHunger: Double
    private var nextOrdinal: Int
    private var canonicalFoods: [FoodItem] = []
    private var model: BrainModel
    private var availableModels: [BrainModel]

    public init(width: Double = 1000, height: Double = 650,
                initialHunger: Double = 0.65,
                profiles: [IndividualProfile] = [],
                brainModel: BrainModel = .flywireV783,
                availableBrainModels: [BrainModel] = [.flywireV783]) {
        self.width = max(180, width)
        self.height = max(180, height)
        self.initialHunger = initialHunger

        var models = availableBrainModels
        if !models.contains(brainModel) { models.insert(brainModel, at: 0) }
        self.availableModels = models.isEmpty ? [.flywireV783] : models
        self.model = self.availableModels.contains(brainModel) ? brainModel : self.availableModels[0]

        let requested: [IndividualProfile]
        if profiles.isEmpty {
            requested = [Self.defaultProfile(ordinal: 0)]
        } else {
            requested = Array(profiles.sorted {
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(Self.maximumIndividuals))
        }
        self.nextOrdinal = (requested.map(\.ordinal).max() ?? -1) + 1
        self.selectedID = requested[0].id
        self.agents = requested.map { profile in
            var world = SimulationWorld(width: self.width, height: self.height,
                                        initialHunger: initialHunger,
                                        initialPosition: Self.position(for: profile.ordinal,
                                                                      width: self.width,
                                                                      height: self.height))
            world.restoreMemory(profile.memory)
            return Agent(profile: profile, world: world)
        }
        rebuildSnapshot()
    }

    public var individualCount: Int { agents.count }
    public var individualIDs: [UUID] { agents.map { $0.profile.id } }
    public var selectedIndividualID: UUID { selectedID }
    public var brainModel: BrainModel { model }
    public var availableBrainModels: [BrainModel] { availableModels }
    public var profiles: [IndividualProfile] {
        agents.map {
            var profile = $0.profile
            profile.memory = $0.world.memory.memoryForPersistence
            return profile
        }
    }

    /// Updates the list after the runtime has verified which datasets are
    /// actually ready. The current model remains selected until an explicit
    /// atomic switch action arrives.
    public mutating func setAvailableBrainModels(_ models: [BrainModel]) {
        var unique: [BrainModel] = []
        for candidate in models where !unique.contains(candidate) { unique.append(candidate) }
        if !unique.contains(model) { unique.insert(model, at: 0) }
        availableModels = unique.isEmpty ? [.flywireV783] : unique
        rebuildSnapshot()
    }

    /// Refreshes the public frame after a group of per-individual advances.
    /// Runtime metadata set by the app is retained by `rebuildSnapshot`.
    public mutating func refresh() { rebuildSnapshot() }

    /// Runtime-only metadata is kept outside the individual state so the core
    /// can be used by both the app and headless diagnostics.
    public mutating func updateRuntimeMetadata(
        isReady: Bool? = nil,
        status: String? = nil,
        error: String?? = nil,
        neuronCount: Int? = nil,
        edgeCount: Int? = nil,
        realtimeFactor: Double? = nil
    ) {
        if let isReady { snapshot.isReady = isReady }
        if let status { snapshot.status = status }
        if let error { snapshot.error = error }
        if let neuronCount { snapshot.neuronCount = neuronCount }
        if let edgeCount { snapshot.edgeCount = edgeCount }
        if let realtimeFactor { snapshot.realtimeFactor = realtimeFactor }
    }

    public mutating func resize(width newWidth: Double, height newHeight: Double) {
        guard newWidth.isFinite, newHeight.isFinite,
              newWidth >= 180, newHeight >= 180 else { return }
        let sx = newWidth / width
        let sy = newHeight / height
        func scale(_ point: Point2) -> Point2 {
            Point2(x: point.x * sx, y: point.y * sy)
        }
        for index in canonicalFoods.indices {
            canonicalFoods[index].position = scale(canonicalFoods[index].position)
        }
        width = newWidth
        height = newHeight
        for index in agents.indices {
            agents[index].world.resize(width: newWidth, height: newHeight)
            agents[index].world.syncFoods(canonicalFoods)
        }
        rebuildSnapshot()
    }

    /// Applies population-wide or selected-individual actions. Food is added
    /// once to the canonical environment, while touch is sent only to the
    /// selected member.
    public mutating func perform(_ action: UserAction) {
        switch action {
        case .placeFood(let point):
            guard let first = agents.indices.first else { return }
            agents[first].world.syncFoods(canonicalFoods)
            agents[first].world.perform(.placeFood(point))
            canonicalFoods = agents[first].world.snapshot.foods
            syncFoodsToAgents()
        case .placeFoodKind(let point, let kind):
            guard let first = agents.indices.first else { return }
            agents[first].world.syncFoods(canonicalFoods)
            agents[first].world.perform(.placeFoodKind(point, kind))
            canonicalFoods = agents[first].world.snapshot.foods
            syncFoodsToAgents()
        case .castShadow(let point):
            for index in agents.indices {
                agents[index].world.perform(.castShadow(point))
            }
        case .touchFly:
            if let index = selectedIndex {
                agents[index].world.perform(.touchFly)
            }
        case .clearFood:
            canonicalFoods.removeAll()
            syncFoodsToAgents()
        case .togglePause, .toggleSensory:
            for index in agents.indices {
                agents[index].world.perform(action)
            }
        case .reset:
            resetBodies()
        case .addIndividual:
            addIndividual()
        case .removeSelectedIndividual:
            removeSelectedIndividual()
        case .selectIndividual(let id):
            if individualIDs.contains(id) { selectedID = id }
        case .toggleLearning:
            if let index = selectedIndex { agents[index].world.perform(.toggleLearning) }
        case .clearMemory:
            if let index = selectedIndex { agents[index].world.perform(.clearMemory) }
        case .switchBrainModel(let candidate):
            guard availableModels.contains(candidate) else { break }
            model = candidate
        }
        rebuildSnapshot()
    }

    public mutating func addIndividual() {
        guard agents.count < Self.maximumIndividuals else { return }
        let ordinal = nextOrdinal
        nextOrdinal += 1
        var id = UUID()
        while individualIDs.contains(id) { id = UUID() }
        let learningEnabled = selectedIndex.map { agents[$0].world.memory.learningEnabled } ?? true
        let profile = IndividualProfile(id: id,
                                        ordinal: ordinal,
                                        seed: Self.seed(for: ordinal),
                                        memory: FlyMemory(learningEnabled: learningEnabled))
        var newWorld = SimulationWorld(width: width, height: height,
                                       initialHunger: initialHunger,
                                       initialPosition: Self.position(for: ordinal,
                                                                     width: width,
                                                                     height: height))
        newWorld.restoreMemory(profile.memory)
        // A new member joins the same paused/running frame, sensory toggle,
        // elapsed clock, food list, and shadow phase as its peers.
        if let template = agents.first?.world {
            newWorld.inheritEnvironment(from: template)
        } else {
            newWorld.syncFoods(canonicalFoods)
        }
        agents.append(Agent(
            profile: profile,
            world: newWorld))
        agents[agents.count - 1].world.syncFoods(canonicalFoods)
        if agents.count == 1 { selectedID = profile.id }
        rebuildSnapshot()
    }

    public mutating func removeSelectedIndividual() {
        guard agents.count > Self.minimumIndividuals,
              let index = selectedIndex else { return }
        agents.remove(at: index)
        if !individualIDs.contains(selectedID), let first = agents.first {
            selectedID = first.profile.id
        }
        rebuildSnapshot()
    }

    public mutating func selectIndividual(_ id: UUID) {
        guard individualIDs.contains(id) else { return }
        selectedID = id
        rebuildSnapshot()
    }

    public mutating func calibrate(_ calibration: BrainCalibration, for id: UUID) {
        guard let index = index(of: id) else { return }
        agents[index].world.calibrate(calibration)
        rebuildSnapshot()
    }

    public func sense(_ id: UUID) -> SensoryInput {
        guard let index = index(of: id) else { return SensoryInput() }
        return agents[index].world.sense()
    }

    /// Alias for the runtime's future memory-aware input hook. Until the
    /// memory layer is connected, the raw receptor signal is returned exactly.
    public func neuralInput(_ id: UUID) -> SensoryInput {
        guard let index = index(of: id) else { return SensoryInput() }
        return agents[index].world.neuralInput()
    }

    /// Advances one member against the canonical shared food list. The next
    /// member always receives the updated list, so a food item can never be
    /// consumed twice from the same remaining quantity in one tick.
    @discardableResult
    public mutating func advance(_ id: UUID, neural: NeuralReadout,
                                 input: SensoryInput, dt: Double) -> Double {
        guard !snapshot.isPaused, let index = index(of: id),
              dt.isFinite, dt > 0 else { return 0 }
        agents[index].world.syncFoods(canonicalFoods)
        let before = canonicalFoods
        agents[index].world.advance(neural: neural, input: input, dt: dt)
        canonicalFoods = agents[index].world.snapshot.foods
        syncFoodsToAgents()
        rebuildSnapshot()
        return Self.consumedAmount(before: before, after: canonicalFoods)
    }

    /// Restores body/environment state for the existing profiles while keeping
    /// IDs, ordinals, and deterministic seeds. Brain engines are reset by the
    /// app runtime; this method only owns the world side of reset.
    public mutating func resetBodies() {
        let existing = agents.map(\.profile)
        let learningByID = Dictionary(uniqueKeysWithValues: agents.map {
            ($0.profile.id, $0.world.memory.learningEnabled)
        })
        agents = existing.map { profile in
            var world = SimulationWorld(width: width, height: height,
                                        initialHunger: initialHunger,
                                        initialPosition: Self.position(for: profile.ordinal,
                                                                      width: width,
                                                                      height: height))
            world.restoreMemory(FlyMemory(learningEnabled: learningByID[profile.id] ?? true))
            return Agent(profile: profile, world: world)
        }
        canonicalFoods.removeAll()
        selectedID = individualIDs.contains(selectedID) ? selectedID : (agents[0].profile.id)
        rebuildSnapshot()
    }

    private var selectedIndex: Int? { index(of: selectedID) }

    private func index(of id: UUID) -> Int? {
        agents.firstIndex { $0.profile.id == id }
    }

    private mutating func syncFoodsToAgents() {
        for index in agents.indices {
            agents[index].world.syncFoods(canonicalFoods)
        }
    }

    private mutating func rebuildSnapshot() {
        guard !agents.isEmpty else { return }
        syncFoodsToAgents()
        let old = snapshot
        var frame = WorldSnapshot()
        frame.width = width
        frame.height = height
        frame.foods = canonicalFoods
        frame.selectedIndividualID = selectedID
        frame.brainModel = model
        frame.availableBrainModels = availableModels
        frame.learningEnabled = old.learningEnabled
        frame.isReady = old.isReady
        frame.status = old.status
        frame.error = old.error
        frame.neuronCount = old.neuronCount
        frame.edgeCount = old.edgeCount
        frame.realtimeFactor = old.realtimeFactor

        frame.individuals = agents.map { agent in
            let state = agent.world.snapshot
            return IndividualSnapshot(id: agent.profile.id,
                                      ordinal: agent.profile.ordinal,
                                      seed: agent.profile.seed,
                                      fly: state.fly,
                                      body: state.body,
                                      sensory: state.sensory,
                                      neural: state.neural,
                                      motor: state.motor,
                                      memory: state.memory)
        }
        if let selectedIndex {
            let state = agents[selectedIndex].world.snapshot
            frame.fly = state.fly
            frame.body = state.body
            frame.memory = state.memory
            frame.sensory = state.sensory
            frame.neural = state.neural
            frame.motor = state.motor
            frame.shadowPosition = state.shadowPosition
            frame.shadowStrength = state.shadowStrength
            frame.elapsed = state.elapsed
            frame.isPaused = state.isPaused
            frame.sensoryEnabled = state.sensoryEnabled
            frame.learningEnabled = state.memory.learningEnabled
        }
        snapshot = frame
    }

    private static func consumedAmount(before: [FoodItem], after: [FoodItem]) -> Double {
        let remaining = after.reduce(0.0) { $0 + $1.remaining }
        let beforeTotal = before.reduce(0.0) { $0 + $1.remaining }
        // Depleted items no longer appear in `after`, so total difference is
        // the exact amount that was removed by this member.
        return max(0, beforeTotal - remaining)
    }

    private static func defaultProfile(ordinal: Int) -> IndividualProfile {
        IndividualProfile(id: defaultID(for: ordinal), ordinal: ordinal,
                           seed: seed(for: ordinal))
    }

    private static func defaultID(for ordinal: Int) -> UUID {
        let suffix = max(1, ordinal + 1)
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix))!
    }

    private static func seed(for ordinal: Int) -> UInt32 {
        let seeds: [UInt32] = [42, 104729, 209759, 314573]
        if ordinal < seeds.count { return seeds[ordinal] }
        return 42 &+ UInt32(ordinal) &* 104729
    }

    private static func position(for ordinal: Int, width: Double, height: Double) -> Point2 {
        let columns = 2
        let column = ordinal % columns
        let row = (ordinal / columns) % 2
        let x = width * (0.40 + Double(column) * 0.06)
        let y = height * (0.52 + Double(row) * 0.08)
        return Point2(x: x, y: y)
    }
}
