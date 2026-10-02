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
    func stop() { generation &+= 1; runtime?.stop(); runtime = nil }
    func perform(_ action: UserAction) { runtime?.perform(action) }
    func resize(width: Double, height: Double) { runtime?.resize(width: width, height: height) }
}

/// Owns every mutable simulation object on a dedicated serial queue.
private final class SimulationRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "live.neurofly.brain", qos: .userInitiated)
    private let update: @Sendable (WorldSnapshot) -> Void
    private var brain: BrainEngine?
    private var calibration: BrainCalibration?
    private var world = SimulationWorld()
    private var timer: DispatchSourceTimer?
    private var errorMessage: String?
    private var status = "실제 연결 데이터를 확인하는 중…"
    private var frameNumber = 0
    private var intervalStart = ProcessInfo.processInfo.systemUptime
    private var intervalSimulated: Double = 0
    private var realtimeFactor: Double = 0

    init(update: @escaping @Sendable (WorldSnapshot) -> Void) { self.update = update }

    func start() {
        queue.async { [self] in
            publish()
            do {
                brain = try BrainEngine(dataDirectory: DataLocator.directory(), seed: 42)
                status = "좌우 신경 반응을 보정하는 중…"
                publish()
                try calibrate()
                status = "먹이나 자극을 놓아 반응을 살펴보세요."
                intervalStart = ProcessInfo.processInfo.systemUptime
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
                source.setEventHandler { [weak self] in self?.tick() }
                timer = source
                source.resume()
                publish()
            } catch { fail(error) }
        }
    }

    func stop() { queue.async { [self] in timer?.cancel(); timer = nil; brain = nil } }

    func resize(width: Double, height: Double) {
        queue.async { [self] in world.resize(width: width, height: height); publish() }
    }

    func perform(_ action: UserAction) {
        queue.async { [self] in
            world.perform(action)
            if case .reset = action {
                do {
                    try calibrate()
                    frameNumber = 0
                    intervalSimulated = 0
                    intervalStart = ProcessInfo.processInfo.systemUptime
                } catch { fail(error) }
            }
            if case .togglePause = action {
                intervalSimulated = 0
                intervalStart = ProcessInfo.processInfo.systemUptime
            }
            publish()
        }
    }

    private func calibrate() throws {
        guard let brain else { return }
        if calibration == nil { calibration = try BrainCalibration.measure(brain: brain) }
        else { try BrainCalibration.prepare(brain: brain) }
        if let calibration { world.calibrate(calibration) }
    }

    private func tick() {
        guard let brain, errorMessage == nil, !world.snapshot.isPaused else { return }
        do {
            // 33, 33, 34 ms: exactly one second of model time per 30 frames.
            let milliseconds = frameNumber % 3 == 2 ? 34 : 33
            frameNumber += 1
            let input = world.sense()
            let rates = try brain.advance(milliseconds: milliseconds, input: input,
                                          sensoryEnabled: world.snapshot.sensoryEnabled)
            world.advance(neural: rates, input: input, dt: Double(milliseconds) / 1000)
            intervalSimulated += Double(milliseconds) / 1000
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - intervalStart
            if elapsed >= 1 {
                realtimeFactor = intervalSimulated / elapsed
                intervalSimulated = 0; intervalStart = now
            }
            publish()
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "신경망을 실행할 수 없습니다."
        timer?.cancel(); timer = nil
        publish()
    }

    private func publish() {
        var frame = world.snapshot
        frame.isReady = brain != nil && errorMessage == nil && timer != nil
        frame.error = errorMessage
        frame.status = status
        frame.neuronCount = brain?.neuronCount ?? 0
        frame.edgeCount = brain?.edgeCount ?? 0
        frame.realtimeFactor = realtimeFactor
        update(frame)
    }
}
