import Foundation
import NeuroFlyCore

@MainActor
final class SimulationSession {
    private(set) var snapshot = WorldSnapshot()
    var onUpdate: ((WorldSnapshot) -> Void)?
    private var runtime: SimulationRuntime?
    private var generation: UInt64 = 0

    func start() {
        guard runtime == nil else { return }
        generation &+= 1
        let startedGeneration = generation
        let runtime = SimulationRuntime { [weak self] frame in
            DispatchQueue.main.async {
                guard let self, self.generation == startedGeneration else { return }
                self.snapshot = frame
                self.onUpdate?(frame)
            }
        }
        self.runtime = runtime
        runtime.start()
    }
    func stop() {
        generation &+= 1
        runtime?.stop()
        runtime = nil
    }
    func perform(_ action: UserAction) { runtime?.perform(action) }
    func resize(width: Double, height: Double) { runtime?.resize(width: width, height: height) }
}

/// Each member owns a complete, independent neural state. One serial queue
/// advances them against the shared food supply and publishes a whole frame.
private final class SimulationRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "live.neurofly.brain", qos: .userInitiated)
    private let update: @Sendable (WorldSnapshot) -> Void
    private var brains: [UUID: BrainEngine] = [:]
    private var calibrations: [String: BrainCalibration] = [:]
    private var population = PopulationWorld()
    private var timer: DispatchSourceTimer?
    private var errorMessage: String?
    private var status = "실제 연결 데이터를 확인하는 중…"
    private var persistenceWarning: String?
    private var saveWarning: String?
    private var persistenceEnabled = true
    private var availableModels: [BrainModel] = []
    private var isPreparing = false
    private var frameNumber = 0
    private var intervalStart = ProcessInfo.processInfo.systemUptime
    private var intervalSimulated: Double = 0
    private var realtimeFactor: Double = 0
    private var lastSaveTime: Double = 0
    private let store: ColonyStore

    init(update: @escaping @Sendable (WorldSnapshot) -> Void) {
        self.update = update
        let root: URL
        if let explicit = ProcessInfo.processInfo.environment["NEUROFLY_STATE_DIR"] {
            root = URL(fileURLWithPath: explicit, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NeuroFly", isDirectory: true)
        }
        store = ColonyStore(url: root.appendingPathComponent("colony-v1.json"))
    }

    func start() {
        queue.async { [self] in
            publish()
            do {
                let available = DataLocator.availableModels
                availableModels = available
                var archive: ColonyArchive?
                do {
                    archive = try store.load()
                } catch {
                    // A broken checkpoint remains recoverable on disk.
                    do {
                        _ = try store.preserveUnreadableArchive()
                        persistenceWarning = "읽지 못한 기억 파일을 보관하고 새로 시작했습니다."
                    } catch {
                        persistenceEnabled = false
                        persistenceWarning = "기억 파일을 읽지 못해 이번 실행의 자동 저장을 중단했습니다."
                    }
                }
                let model = archive.map { available.contains($0.brainModel) ? $0.brainModel : DataLocator.preferredModel }
                    ?? DataLocator.preferredModel
                if let archive, archive.brainModel != model {
                    persistenceWarning = "저장된 뇌 데이터가 없어 \(model.displayName)으로 시작했습니다. 기억은 유지합니다."
                }
                var candidate = PopulationWorld(profiles: archive?.profiles ?? [], brainModel: model,
                                                availableBrainModels: available)
                if let selected = archive?.selectedIndividualID { candidate.selectIndividual(selected) }
                // Startup has no running engines to replace. Expose the
                // restored identities/model while loading, and retain them
                // for error recovery if engine preparation fails.
                population = candidate
                try installBrains(model: model, into: &candidate)
                population = candidate
                status = "먹이와 자극으로 각 개체의 반응과 기억을 살펴보세요."
                startTimer()
                save()
                publish()
            } catch { fail(error) }
        }
    }

    /// Flush the small checkpoint before AppKit finishes application teardown.
    /// No main-queue work is awaited by the simulation queue.
    func stop() {
        queue.sync { [self] in
            timer?.cancel(); timer = nil
            save()
            brains.removeAll()
        }
    }

    func resize(width: Double, height: Double) {
        queue.async { [self] in
            population.resize(width: width, height: height)
            publish()
        }
    }

    func perform(_ action: UserAction) {
        queue.async { [self] in
            do {
                switch action {
                case .switchBrainModel(let model):
                    availableModels = DataLocator.availableModels
                    guard availableModels.contains(model) else {
                        throw BrainEngineError.invalidData("\(model.displayName) 데이터가 준비되지 않았습니다.")
                    }
                    guard model != population.brainModel || errorMessage != nil else { return }
                    var candidate = population
                    candidate.setAvailableBrainModels(availableModels)
                    try installBrains(model: model, into: &candidate)
                    candidate.perform(action)
                    population = candidate
                    errorMessage = nil
                    status = "\(model.displayName)으로 전환했습니다. 개체별 기억은 유지됩니다."
                    startTimer()
                case .addIndividual:
                    guard errorMessage == nil,
                          population.individualCount < PopulationWorld.maximumIndividuals else { return }
                    var candidate = population
                    candidate.perform(action)
                    guard let profile = candidate.profiles.first(where: { brains[$0.id] == nil }) else { return }
                    status = "새 개체의 신경망을 준비하는 중…"
                    publish()
                    let brain = try makeBrain(profile: profile, model: population.brainModel, world: &candidate)
                    brains[profile.id] = brain
                    candidate.selectIndividual(profile.id)
                    population = candidate
                    status = "개체 #\(profile.ordinal + 1) 추가 완료"
                    resetTiming()
                case .removeSelectedIndividual:
                    let previousCount = population.individualCount
                    population.perform(action)
                    let keep = Set(population.individualIDs)
                    brains = brains.filter { keep.contains($0.key) }
                    if population.individualCount < previousCount {
                        status = "선택한 개체를 제거했습니다. 현재 \(population.individualCount)개입니다."
                    }
                case .reset:
                    var candidate = population
                    candidate.perform(action)
                    try installBrains(model: population.brainModel, into: &candidate)
                    population = candidate
                    frameNumber = 0
                    errorMessage = nil
                    startTimer()
                    status = "모든 개체의 몸 상태와 기억을 초기화했습니다."
                default:
                    population.perform(action)
                    if case .togglePause = action { resetTiming() }
                }
                save()
                publish()
            } catch {
                // Add/model replacement is transactional. Keep the old colony
                // running if a replacement could not be allocated or loaded.
                status = "요청을 적용하지 못했습니다: \(error.localizedDescription)"
                publish()
            }
        }
    }

    private func calibrationKey(model: BrainModel, seed: UInt32) -> String {
        "\(model.rawValue):\(seed)"
    }

    private func makeBrain(profile: IndividualProfile, model: BrainModel,
                           world: inout PopulationWorld) throws -> BrainEngine {
        isPreparing = true
        defer { isPreparing = false }
        status = "\(model.displayName) · 개체 \(profile.ordinal + 1)의 신경망을 준비하는 중…"
        publish()
        let brain = try BrainEngine(dataDirectory: DataLocator.directory(model: model), seed: profile.seed, model: model)
        let key = calibrationKey(model: model, seed: profile.seed)
        let calibration: BrainCalibration
        if let cached = calibrations[key] {
            calibration = cached
        } else {
            status = "\(model.displayName) · 개체 \(profile.ordinal + 1)의 좌우 반응을 보정하는 중…"
            publish()
            calibration = try BrainCalibration.measure(brain: brain, seed: profile.seed)
            calibrations[key] = calibration
        }
        try BrainCalibration.prepare(brain: brain, seed: profile.seed)
        world.calibrate(calibration, for: profile.id)
        return brain
    }

    private func installBrains(model: BrainModel, into candidate: inout PopulationWorld) throws {
        var replacement: [UUID: BrainEngine] = [:]
        for profile in candidate.profiles {
            replacement[profile.id] = try makeBrain(profile: profile, model: model, world: &candidate)
        }
        // Commit only after every required independent engine is ready.
        brains = replacement
        resetTiming()
    }

    private func startTimer() {
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
        resetTiming()
    }

    private func resetTiming() {
        intervalSimulated = 0
        realtimeFactor = 0
        intervalStart = ProcessInfo.processInfo.systemUptime
    }

    private func tick() {
        guard errorMessage == nil, !population.snapshot.isPaused else { return }
        do {
            let milliseconds = frameNumber % 3 == 2 ? 34 : 33
            frameNumber += 1
            for id in population.individualIDs {
                guard let brain = brains[id],
                      let individual = population.snapshot.individuals.first(where: { $0.id == id }) else {
                    throw BrainEngineError.invalidData("an individual has no independent brain")
                }
                let raw = population.sense(id)
                let rates = try brain.advance(milliseconds: milliseconds, input: population.neuralInput(id),
                                              sensoryEnabled: population.snapshot.sensoryEnabled,
                                              foodDrive: individual.body.foodDrive)
                population.advance(id, neural: rates, input: raw, dt: Double(milliseconds) / 1000)
            }
            population.refresh()
            intervalSimulated += Double(milliseconds) / 1000
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - intervalStart
            if elapsed >= 1 {
                realtimeFactor = intervalSimulated / elapsed
                intervalSimulated = 0; intervalStart = now
            }
            if now - lastSaveTime >= 5 { save() }
            publish()
        } catch { fail(error) }
    }

    private func save() {
        guard persistenceEnabled, !brains.isEmpty else { return }
        do {
            try store.save(ColonyArchive(brainModel: population.brainModel,
                                        selectedIndividualID: population.selectedIndividualID,
                                        profiles: population.profiles))
            lastSaveTime = ProcessInfo.processInfo.systemUptime
            saveWarning = nil
        } catch {
            saveWarning = "기억을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "신경망을 실행할 수 없습니다. 다른 준비된 뇌 모델을 선택할 수 있습니다."
        timer?.cancel(); timer = nil
        publish()
    }

    private func publish() {
        var frame = population.snapshot
        frame.isReady = !brains.isEmpty && errorMessage == nil && timer != nil && !isPreparing
        frame.error = errorMessage
        frame.status = ([status] + [persistenceWarning, saveWarning].compactMap { $0 }).joined(separator: " ")
        frame.availableBrainModels = availableModels
        let brain = brains[population.selectedIndividualID]
        frame.neuronCount = brain?.neuronCount ?? 0
        frame.edgeCount = brain?.edgeCount ?? 0
        frame.realtimeFactor = realtimeFactor
        update(frame)
    }
}
