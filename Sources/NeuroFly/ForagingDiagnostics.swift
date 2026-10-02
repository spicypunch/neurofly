import Foundation
import NeuroFlyCore

private struct ForagingConfiguration {
    let seed: UInt32
    let seconds: Double
    /// Additional input-free brain warmup after BrainCalibration.prepare's
    /// fixed 500 ms baseline pass. The world and decoder start unchanged.
    let warmupSeconds: Double
    let distances: [Double]
    let bearingsDegrees: [Double]
    let trialCap: Int?
    let width: Double
    let height: Double

    init(arguments: [String]) throws {
        var seed: UInt32 = 42
        var seconds = 30.0
        var warmupSeconds = 0.5
        var distances = [120.0, 220.0, 360.0]
        var bearings = [0.0, 45.0, -45.0, 90.0, -90.0, 180.0]
        var trialCap: Int?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--foraging" {
                index += 1
                continue
            }

            let name: String
            let value: String?
            if let separator = argument.firstIndex(of: "=") {
                name = String(argument[..<separator])
                value = String(argument[argument.index(after: separator)...])
            } else {
                name = argument
                value = nil
            }

            switch name {
            case "--foraging-seconds":
                let raw = try Self.optionValue(name: name, inline: value,
                                               arguments: arguments, index: &index)
                seconds = try Self.positiveDouble(raw, option: name)
            case "--foraging-warmup-seconds":
                let raw = try Self.optionValue(name: name, inline: value,
                                               arguments: arguments, index: &index)
                warmupSeconds = try Self.minimumDouble(raw, minimum: 0.5, option: name)
            case "--foraging-distances":
                let raw = try Self.optionValue(name: name, inline: value,
                                               arguments: arguments, index: &index)
                distances = try Self.doubleList(raw, option: name, positive: true)
            case "--foraging-bearings":
                let raw = try Self.optionValue(name: name, inline: value,
                                               arguments: arguments, index: &index)
                bearings = try Self.doubleList(raw, option: name, positive: false)
            case "--foraging-trial-cap", "--foraging-max-trials":
                let raw = try Self.optionValue(name: name, inline: value,
                                               arguments: arguments, index: &index)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw ForagingDiagnosticsError.invalidOption(name, raw)
                }
                trialCap = parsed
            case "--foraging-seed":
                let raw = try Self.optionValue(name: name, inline: value,
                                               arguments: arguments, index: &index)
                guard let parsed = UInt32(raw) else {
                    throw ForagingDiagnosticsError.invalidOption(name, raw)
                }
                seed = parsed
            default:
                throw ForagingDiagnosticsError.unknownOption(argument)
            }
            index += 1
        }

        guard !distances.isEmpty, !bearings.isEmpty else {
            throw ForagingDiagnosticsError.invalidConfiguration("거리와 방위각은 하나 이상 필요합니다.")
        }
        self.seed = seed
        self.seconds = seconds
        self.warmupSeconds = warmupSeconds
        self.distances = distances
        self.bearingsDegrees = bearings
        self.trialCap = trialCap
        // The wide desktop canvas keeps every requested 360 px target away from
        // the enclosure. These coordinates are diagnostic setup only; they do
        // not cross the world -> connectome sensory boundary.
        self.width = 2560
        self.height = 1400
    }

    private static func optionValue(name: String, inline: String?, arguments: [String],
                                    index: inout Int) throws -> String {
        if let inline { return inline }
        guard index + 1 < arguments.count else {
            throw ForagingDiagnosticsError.missingOptionValue(name)
        }
        index += 1
        return arguments[index]
    }

    private static func positiveDouble(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite, value > 0 else {
            throw ForagingDiagnosticsError.invalidOption(option, raw)
        }
        return value
    }

    private static func minimumDouble(_ raw: String, minimum: Double, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite, value >= minimum else {
            throw ForagingDiagnosticsError.invalidOption(option, raw)
        }
        return value
    }

    private static func doubleList(_ raw: String, option: String, positive: Bool) throws -> [Double] {
        let values = try raw.split(separator: ",", omittingEmptySubsequences: false).map { part in
            guard let value = Double(part), value.isFinite, positive ? value > 0 : true else {
                throw ForagingDiagnosticsError.invalidOption(option, raw)
            }
            return value
        }
        guard !values.isEmpty else { throw ForagingDiagnosticsError.invalidOption(option, raw) }
        return values
    }
}

private enum ForagingDiagnosticsError: LocalizedError {
    case missingOptionValue(String)
    case invalidOption(String, String)
    case unknownOption(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .missingOptionValue(let option): return "옵션 값이 없습니다: \(option)"
        case .invalidOption(let option, let value): return "옵션 값이 올바르지 않습니다: \(option)=\(value)"
        case .unknownOption(let option): return "알 수 없는 foraging 옵션입니다: \(option)"
        case .invalidConfiguration(let message): return message
        }
    }
}

private struct ForagingWorldDescription: Codable {
    let width: Double
    let height: Double
    let initialFlyPosition: Point2
    let initialHeadingRadians: Double
    let initialFoodRemaining: Double
}

private struct FirstFiveSecondSummary: Codable {
    let durationSeconds: Double
    let referenceBearingDegrees: Double
    let headingStartRadians: Double
    let headingEndRadians: Double
    let headingDeltaRadians: Double
    let meanHeadingRadians: Double
    let firstProjectionPixels: Double
    let finalProjectionPixels: Double
    let meanProjectionPixels: Double
    let pathDistancePixels: Double
}

private struct PNActivitySummary: Codable {
    let thresholdHz: Double
    let activeFraction: Double
    let meanTotalHz: Double
    let maxTotalHz: Double
    let meanLeftHz: Double
    let meanRightHz: Double
}

private struct ForagingTracePoint: Codable {
    let timeSeconds: Double
    let position: Point2
    let headingRadians: Double
    let speedPixelsPerSecond: Double
    let activity: FlyActivity
    let odorLeft: Float
    let odorRight: Float
    let taste: Float
    let pnTotalHz: Float
    let pnLeftHz: Float
    let pnRightHz: Float
    let turnRadiansPerSecond: Double
    let feedingHz: Float
    let escapeHz: Float
    let body: BodyState
}

private struct ForagingTrialReport: Codable {
    let id: String
    let category: String
    let sensoryEnabled: Bool
    let distancePixels: Double?
    let bearingDegrees: Double?
    let foodPosition: Point2?
    let contactTimeSeconds: Double?
    let consumedFraction: Double
    let minDistancePixels: Double?
    let totalDistancePixels: Double
    let firstFiveSeconds: FirstFiveSecondSummary
    let pnActivity: PNActivitySummary
    let trajectoryDigest: String
    let controlEqualToNoFood: Bool?
    let trace: [ForagingTracePoint]
}

private struct ForagingReport: Codable {
    let schemaVersion: Int
    let seed: UInt32
    let modelSeconds: Double
    let warmupSeconds: Double
    let world: ForagingWorldDescription
    let distancesPixels: [Double]
    let bearingsDegrees: [Double]
    let calibration: BrainCalibration
    let foodTrials: [ForagingTrialReport]
    let noFood: ForagingTrialReport
    let blockedControls: [ForagingTrialReport]
    let blockedControlEqual: Bool
}

private struct ForagingControlSample: Equatable {
    let fly: FlyState
    let neural: NeuralReadout
    let body: BodyState
}

private struct ForagingTrialExecution {
    let report: ForagingTrialReport
    let controlSamples: [ForagingControlSample]
}

private struct FirstWindowSample {
    let heading: Double
    let projection: Double
    let pathDistance: Double
}

private struct ForagingDigest {
    private var hash: UInt64 = 14695981039346656037

    mutating func append(_ value: UInt64) {
        hash ^= value
        hash &*= 1099511628211
    }

    mutating func append(_ value: Double) { append(value.bitPattern) }
    mutating func append(_ value: Float) { append(UInt64(value.bitPattern)) }
    mutating func append(_ value: FlyActivity) {
        for byte in value.rawValue.utf8 { append(UInt64(byte)) }
        append(UInt64(0))
    }

    mutating func append(_ sample: ForagingControlSample) {
        append(sample.fly.position.x)
        append(sample.fly.position.y)
        append(sample.fly.heading)
        append(sample.fly.speed)
        append(sample.fly.activity)
        append(sample.neural.turnLeftHz)
        append(sample.neural.turnRightHz)
        append(sample.neural.forwardHz)
        append(sample.neural.escapeHz)
        append(sample.neural.feedingHz)
        append(sample.neural.groomingHz)
        append(sample.neural.odorRelayLeftHz)
        append(sample.neural.odorRelayRightHz)
        append(sample.neural.populationHz)
        append(sample.body.hunger)
        append(sample.body.foodDrive)
        append(sample.body.consumedFood)
    }

    var hex: String {
        let value = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - value.count)) + value
    }
}

private extension NeuralReadout {
    /// Computation timing is intentionally excluded from deterministic control
    /// comparisons because it is wall-clock instrumentation, not neural state.
    var foragingControlValue: NeuralReadout {
        NeuralReadout(turnLeftHz: turnLeftHz, turnRightHz: turnRightHz,
                      forwardHz: forwardHz, escapeHz: escapeHz,
                      feedingHz: feedingHz, groomingHz: groomingHz,
                      odorRelayLeftHz: odorRelayLeftHz,
                      odorRelayRightHz: odorRelayRightHz,
                      populationHz: populationHz)
    }
}

extension NeuroFlyMain {
    static func runForagingDiagnostics() throws {
        let configuration = try ForagingConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
        let brain = try BrainEngine(dataDirectory: DataLocator.directory(), seed: configuration.seed)
        let calibration = try BrainCalibration.measure(brain: brain, seed: configuration.seed)

        let noFoodExecution = try runForagingTrial(
            brain: brain, calibration: calibration, configuration: configuration,
            id: "noFood", category: "noFood", distance: nil, bearingDegrees: nil,
            foodPosition: nil, sensoryEnabled: true, referenceBearingDegrees: 0)

        var foodTrials: [ForagingTrialReport] = []
        let allFoodCases = configuration.distances.flatMap { distance in
            configuration.bearingsDegrees.map { bearing in (distance, bearing) }
        }
        let selectedFoodCases: [(Double, Double)]
        if let trialCap = configuration.trialCap {
            selectedFoodCases = Array(allFoodCases.prefix(trialCap))
        } else {
            selectedFoodCases = allFoodCases
        }

        for (index, pair) in selectedFoodCases.enumerated() {
            let (distance, bearingDegrees) = pair
            let start = SimulationWorld(width: configuration.width,
                                        height: configuration.height).snapshot.fly.position
            let radians = bearingDegrees * .pi / 180
            let target = Point2(x: start.x + distance * cos(radians),
                                y: start.y + distance * sin(radians))
            let execution = try runForagingTrial(
                brain: brain, calibration: calibration, configuration: configuration,
                id: "food-\(index)-d\(numberLabel(distance))-b\(numberLabel(bearingDegrees))",
                category: "food", distance: distance, bearingDegrees: bearingDegrees,
                foodPosition: target, sensoryEnabled: true,
                referenceBearingDegrees: bearingDegrees)
            foodTrials.append(execution.report)
        }

        let controlDistance = configuration.distances.contains(220) ? 220.0 : configuration.distances[0]
        let controlBearings = [180.0, -90.0, 90.0]
        var blockedControls: [ForagingTrialReport] = []
        var allBlockedEqual = true
        for (index, bearingDegrees) in controlBearings.enumerated() {
            let start = SimulationWorld(width: configuration.width,
                                        height: configuration.height).snapshot.fly.position
            let radians = bearingDegrees * .pi / 180
            let target = Point2(x: start.x + controlDistance * cos(radians),
                                y: start.y + controlDistance * sin(radians))
            let execution = try runForagingTrial(
                brain: brain, calibration: calibration, configuration: configuration,
                id: "blocked-\(index)-d\(numberLabel(controlDistance))-b\(numberLabel(bearingDegrees))",
                category: "blocked", distance: controlDistance,
                bearingDegrees: bearingDegrees, foodPosition: target,
                sensoryEnabled: false, referenceBearingDegrees: bearingDegrees)
            let equal = execution.controlSamples == noFoodExecution.controlSamples
            allBlockedEqual = allBlockedEqual && equal
            blockedControls.append(ForagingTrialReport(
                id: execution.report.id, category: execution.report.category,
                sensoryEnabled: execution.report.sensoryEnabled,
                distancePixels: execution.report.distancePixels,
                bearingDegrees: execution.report.bearingDegrees,
                foodPosition: execution.report.foodPosition,
                contactTimeSeconds: execution.report.contactTimeSeconds,
                consumedFraction: execution.report.consumedFraction,
                minDistancePixels: execution.report.minDistancePixels,
                totalDistancePixels: execution.report.totalDistancePixels,
                firstFiveSeconds: execution.report.firstFiveSeconds,
                pnActivity: execution.report.pnActivity,
                trajectoryDigest: execution.report.trajectoryDigest,
                controlEqualToNoFood: equal,
                trace: execution.report.trace))
        }

        let start = SimulationWorld(width: configuration.width,
                                    height: configuration.height).snapshot.fly.position
        let report = ForagingReport(
            schemaVersion: 1,
            seed: configuration.seed,
            modelSeconds: configuration.seconds,
            warmupSeconds: configuration.warmupSeconds,
            world: ForagingWorldDescription(width: configuration.width,
                                             height: configuration.height,
                                             initialFlyPosition: start,
                                             initialHeadingRadians: 0,
                                             initialFoodRemaining: 1),
            distancesPixels: configuration.distances,
            bearingsDegrees: configuration.bearingsDegrees,
            calibration: calibration,
            foodTrials: foodTrials,
            noFood: noFoodExecution.report,
            blockedControls: blockedControls,
            blockedControlEqual: allBlockedEqual)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func runForagingTrial(
        brain: BrainEngine,
        calibration: BrainCalibration,
        configuration: ForagingConfiguration,
        id: String,
        category: String,
        distance: Double?,
        bearingDegrees: Double?,
        foodPosition: Point2?,
        sensoryEnabled: Bool,
        referenceBearingDegrees: Double
    ) throws -> ForagingTrialExecution {
        try BrainCalibration.prepare(brain: brain, seed: configuration.seed)
        var world = SimulationWorld(width: configuration.width, height: configuration.height)
        world.calibrate(calibration)
        if let foodPosition { world.perform(.placeFood(foodPosition)) }
        if !sensoryEnabled { world.perform(.toggleSensory) }

        // BrainCalibration.prepare establishes the fixed 500 ms baseline. The
        // extra warmup models a running app that has already spent a short
        // input-free interval before the user places food. Keep it out of the
        // world clock so every trial still starts at the same body state.
        var warmupMilliseconds = max(0, Int((configuration.warmupSeconds * 1000).rounded()))
        while warmupMilliseconds > 0 {
            let step = min(50, warmupMilliseconds)
            _ = try brain.advance(milliseconds: step, input: SensoryInput())
            warmupMilliseconds -= step
        }

        let initialPosition = world.snapshot.fly.position
        let initialRemaining = foodPosition == nil ? 0 : 1.0
        let referenceRadians = referenceBearingDegrees * .pi / 180
        let reference = Point2(x: cos(referenceRadians), y: sin(referenceRadians))
        let target = foodPosition
        let durationMilliseconds = max(1, Int((configuration.seconds * 1000).rounded()))
        var simulatedMilliseconds = 0
        var tick = 0
        var previousPosition = initialPosition
        var totalDistance = 0.0
        var minDistance = target.map { initialPosition.distance(to: $0) }
        var contactTime: Double?
        var remainingFood = initialRemaining
        var firstWindowSamples: [FirstWindowSample] = []
        var trace: [ForagingTracePoint] = [ForagingTracePoint(
            timeSeconds: 0, position: initialPosition, headingRadians: world.snapshot.fly.heading,
            speedPixelsPerSecond: world.snapshot.fly.speed,
            activity: world.snapshot.fly.activity, odorLeft: 0, odorRight: 0,
            taste: 0, pnTotalHz: 0, pnLeftHz: 0, pnRightHz: 0,
            turnRadiansPerSecond: 0, feedingHz: 0, escapeHz: 0, body: world.snapshot.body)]
        var controlSamples: [ForagingControlSample] = []
        var pnCount = 0
        var pnActiveCount = 0
        var pnTotalSum = 0.0
        var pnLeftSum = 0.0
        var pnRightSum = 0.0
        var pnMax = 0.0
        let pnThreshold = 30.0
        let firstWindowMilliseconds = min(durationMilliseconds, 5_000)

        while simulatedMilliseconds < durationMilliseconds {
            let patternMilliseconds = [33, 33, 34][tick % 3]
            let milliseconds = min(patternMilliseconds, durationMilliseconds - simulatedMilliseconds)
            let input = world.sense()
            let response = try brain.advance(milliseconds: milliseconds,
                                              input: input,
                                              sensoryEnabled: world.snapshot.sensoryEnabled,
                                              foodDrive: world.snapshot.body.foodDrive)
            world.advance(neural: response, input: input,
                          dt: Double(milliseconds) / 1000)

            simulatedMilliseconds += milliseconds
            tick += 1
            let now = world.snapshot.fly.position
            let movement = previousPosition.distance(to: now)
            totalDistance += movement
            previousPosition = now
            if let target {
                minDistance = min(minDistance ?? .greatestFiniteMagnitude,
                                  now.distance(to: target))
            }
            if contactTime == nil, input.taste > 0 {
                contactTime = Double(simulatedMilliseconds) / 1000
            }
            remainingFood = world.snapshot.foods.reduce(0) { $0 + $1.remaining }

            let pnLeft = Double(response.odorRelayLeftHz)
            let pnRight = Double(response.odorRelayRightHz)
            let pnTotal = pnLeft + pnRight
            pnCount += 1
            if pnTotal > pnThreshold { pnActiveCount += 1 }
            pnTotalSum += pnTotal
            pnLeftSum += pnLeft
            pnRightSum += pnRight
            pnMax = max(pnMax, pnTotal)

            if simulatedMilliseconds <= firstWindowMilliseconds {
                let delta = Point2(x: now.x - initialPosition.x,
                                   y: now.y - initialPosition.y)
                let projection = delta.x * reference.x + delta.y * reference.y
                firstWindowSamples.append(FirstWindowSample(
                    heading: world.snapshot.fly.heading,
                    projection: projection,
                    pathDistance: totalDistance))
            }

            let isTraceBoundary = tick % 30 == 0 || simulatedMilliseconds == durationMilliseconds
            if isTraceBoundary {
                trace.append(ForagingTracePoint(
                    timeSeconds: Double(simulatedMilliseconds) / 1000,
                    position: now, headingRadians: world.snapshot.fly.heading,
                    speedPixelsPerSecond: world.snapshot.fly.speed,
                    activity: world.snapshot.fly.activity,
                    odorLeft: input.odorLeft, odorRight: input.odorRight,
                    taste: input.taste, pnTotalHz: Float(pnTotal),
                    pnLeftHz: response.odorRelayLeftHz, pnRightHz: response.odorRelayRightHz,
                    turnRadiansPerSecond: world.snapshot.motor.turnRate,
                    feedingHz: response.feedingHz, escapeHz: response.escapeHz,
                    body: world.snapshot.body))
            }
            controlSamples.append(ForagingControlSample(
                fly: world.snapshot.fly, neural: response.foragingControlValue,
                body: world.snapshot.body))
        }

        let firstSummary = makeFirstWindowSummary(
            samples: firstWindowSamples, durationMilliseconds: firstWindowMilliseconds,
            referenceBearingDegrees: referenceBearingDegrees)
        let pnSummary = PNActivitySummary(
            thresholdHz: pnThreshold,
            activeFraction: pnCount == 0 ? 0 : Double(pnActiveCount) / Double(pnCount),
            meanTotalHz: pnCount == 0 ? 0 : pnTotalSum / Double(pnCount),
            maxTotalHz: pnMax,
            meanLeftHz: pnCount == 0 ? 0 : pnLeftSum / Double(pnCount),
            meanRightHz: pnCount == 0 ? 0 : pnRightSum / Double(pnCount))
        var digest = ForagingDigest()
        for sample in controlSamples { digest.append(sample) }
        let consumed = initialRemaining == 0 ? 0 : max(0, min(1, initialRemaining - remainingFood))
        let report = ForagingTrialReport(
            id: id, category: category, sensoryEnabled: sensoryEnabled,
            distancePixels: distance, bearingDegrees: bearingDegrees,
            foodPosition: foodPosition, contactTimeSeconds: contactTime,
            consumedFraction: consumed, minDistancePixels: minDistance,
            totalDistancePixels: totalDistance, firstFiveSeconds: firstSummary,
            pnActivity: pnSummary, trajectoryDigest: digest.hex,
            controlEqualToNoFood: nil, trace: trace)
        return ForagingTrialExecution(report: report, controlSamples: controlSamples)
    }

    private static func makeFirstWindowSummary(
        samples: [FirstWindowSample], durationMilliseconds: Int,
        referenceBearingDegrees: Double
    ) -> FirstFiveSecondSummary {
        guard let first = samples.first, let last = samples.last else {
            return FirstFiveSecondSummary(
                durationSeconds: Double(durationMilliseconds) / 1000,
                referenceBearingDegrees: referenceBearingDegrees,
                headingStartRadians: 0, headingEndRadians: 0,
                headingDeltaRadians: 0, meanHeadingRadians: 0,
                firstProjectionPixels: 0, finalProjectionPixels: 0,
                meanProjectionPixels: 0, pathDistancePixels: 0)
        }
        let headingSin = samples.reduce(0.0) { $0 + sin($1.heading) }
        let headingCos = samples.reduce(0.0) { $0 + cos($1.heading) }
        let meanHeading = atan2(headingSin, headingCos)
        let delta = atan2(sin(last.heading - first.heading),
                          cos(last.heading - first.heading))
        return FirstFiveSecondSummary(
            durationSeconds: Double(durationMilliseconds) / 1000,
            referenceBearingDegrees: referenceBearingDegrees,
            headingStartRadians: first.heading,
            headingEndRadians: last.heading,
            headingDeltaRadians: delta,
            meanHeadingRadians: meanHeading,
            firstProjectionPixels: samples.first?.projection ?? 0,
            finalProjectionPixels: last.projection,
            meanProjectionPixels: samples.reduce(0) { $0 + $1.projection } / Double(samples.count),
            pathDistancePixels: last.pathDistance)
    }

    private static func numberLabel(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(value).replacingOccurrences(of: ".", with: "p")
    }
}
