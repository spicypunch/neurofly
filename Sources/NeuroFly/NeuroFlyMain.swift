import AppKit
import Foundation
import NeuroFlyCore

@main
struct NeuroFlyMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") || args.contains("--benchmark") || args.contains("--experiment") || args.contains("--foraging") {
            do {
                if args.contains("--foraging") { try runForagingDiagnostics() }
                else if args.contains("--experiment") { try runWorldExperiment() }
                else { try runDiagnostics(benchmark: args.contains("--benchmark")) }
            }
            catch { fputs("NeuroFly: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let session = SimulationSession()
        let delegate = DesktopAppController(session: session)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    static func runDiagnostics(benchmark: Bool) throws {
        let brain = try BrainEngine(dataDirectory: DataLocator.directory(), seed: 42)
        var result: [String: Any] = ["neurons": brain.neuronCount, "edges": brain.edgeCount,
                                     "gpu": brain.gpuName, "mapping": brain.mappingSummary]
        if benchmark {
            let start = ProcessInfo.processInfo.systemUptime
            var last = NeuralReadout()
            for _ in 0..<200 { last = try brain.advance(milliseconds: 50, input: SensoryInput(odorLeft: 0.5, odorRight: 0.25)) }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            result["simulatedSeconds"] = 10
            result["wallSeconds"] = seconds
            result["simulationToWallRatio"] = 10 / seconds
            result["last"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(last))
        } else {
            let cases: [(String, SensoryInput, Bool)] = [
                ("baseline", SensoryInput(), true),
                ("fruitLeft", SensoryInput(odorLeft: 1, odorRight: 0.1), true),
                ("fruitRight", SensoryInput(odorLeft: 0.1, odorRight: 1), true),
                ("taste", SensoryInput(taste: 1), true),
                ("loom", SensoryInput(loomingLeft: 1, loomingRight: 1), true),
                ("touch", SensoryInput(touch: 1), true),
                ("blocked", SensoryInput(odorLeft: 1, taste: 1, loomingLeft: 1, touch: 1), false)
            ]
            var responses: [String: Any] = [:]
            for (name, input, enabled) in cases {
                try brain.reset(seed: 42)
                for _ in 0..<10 { _ = try brain.advance(milliseconds: 50, input: SensoryInput()) }
                var samples: [[String: Any]] = []
                for _ in 0..<10 {
                    let value = try brain.advance(milliseconds: 50, input: input, sensoryEnabled: enabled)
                    samples.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any])
                }
                responses[name] = samples
            }
            result["responses"] = responses
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func runWorldExperiment() throws {
        let brain = try BrainEngine(dataDirectory: DataLocator.directory(), seed: 42)
        var results: [String: Any] = [:]
        let calibration = try BrainCalibration.measure(brain: brain)
        results["calibration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(calibration))
        for name in ["noFood", "foodLeft", "foodCenter", "foodRight", "foodBlocked"] {
            try BrainCalibration.prepare(brain: brain)
            var world = SimulationWorld()
            world.calibrate(calibration)
            let offsetY: Double = name == "foodRight" ? -60 : name == "foodCenter" ? 0 : 60
            let target = Point2(x: world.snapshot.fly.position.x + 140, y: world.snapshot.fly.position.y + offsetY)
            if name != "noFood" { world.perform(.placeFood(target)) }
            if name == "foodBlocked" { world.perform(.toggleSensory) }
            var traces: [[String: Any]] = []
            var minDistance = world.snapshot.fly.position.distance(to: target)
            var tasteFrames = 0, feedingFrames = 0
            // Use the same 30 s observation budget as --foraging. A return
            // approach can make contact late in the old 12 s window; keep the
            // actual contact/consumption gate rather than counting PN activity.
            for tick in 0..<900 {
                let milliseconds = tick % 3 == 2 ? 34 : 33
                let input = world.sense()
                let response = try brain.advance(milliseconds: milliseconds, input: input, sensoryEnabled: world.snapshot.sensoryEnabled)
                world.advance(neural: response, input: input, dt: Double(milliseconds) / 1000)
                minDistance = min(minDistance, world.snapshot.fly.position.distance(to: target))
                if input.taste > 0 { tasteFrames += 1 }
                if world.snapshot.fly.activity == .feeding { feedingFrames += 1 }
                if tick % 30 == 29 {
                    traces.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(world.snapshot)) as! [String: Any])
                }
            }
            results[name] = ["minDistance": minDistance, "tasteFrames": tasteFrames,
                             "feedingFrames": feedingFrames, "trace": traces]
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
