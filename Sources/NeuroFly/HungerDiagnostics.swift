import Foundation
import NeuroFlyCore

extension NeuroFlyMain {
    static func runHungerDiagnostics() throws {
        let seed: UInt32 = 42
        let width = 2560.0, height = 1400.0
        let model = try DataLocator.commandLineModel()
        let brain = try BrainEngine(dataDirectory: DataLocator.directory(model: model), seed: seed, model: model)
        let calibration = try BrainCalibration.measure(brain: brain, seed: seed)
        try BrainCalibration.prepare(brain: brain, seed: seed)

        var world = SimulationWorld(width: width, height: height, initialHunger: 0.65)
        world.calibrate(calibration)
        let start = world.snapshot.fly.position
        let firstPosition = Point2(x: start.x + 120, y: start.y)
        world.perform(.placeFood(firstPosition))

        func remainingFood() -> Double { world.snapshot.foods.reduce(0) { $0 + $1.remaining } }
        func point(_ value: Point2) -> [String: Any] { ["x": value.x, "y": value.y] }
        func milestone(_ name: String, _ time: Double) -> [String: Any] {
            ["name": name, "timeSeconds": time, "hunger": world.snapshot.body.hunger,
             "foodDrive": world.snapshot.body.foodDrive,
             "consumedFood": world.snapshot.body.consumedFood,
             "remainingFood": remainingFood()]
        }

        var milestones: [[String: Any]] = [milestone("initial", 0)]
        var trace: [[String: Any]] = []
        var phase = "firstFood"
        var simulatedMilliseconds = 0
        var tick = 0
        var firstFullTime: Double?
        var clearTime: Double?
        var secondPlacementTime: Double?
        var secondFullTime: Double?
        var secondPosition: Point2?
        var firstFoodConsumed = 0.0
        var secondFoodConsumed = 0.0
        var firstFoodRemainingAtClear = 0.0
        var movementDuringFull = 0.0
        var maxPNDuringHungry = 0.0
        var maxPNDuringSettledFull = 0.0
        var clearFoodBodyUnchanged = false

        while simulatedMilliseconds < 360_000 && secondFullTime == nil {
            let milliseconds = tick % 3 == 2 ? 34 : 33
            let before = world.snapshot
            let raw = world.sense()
            let drive = before.body.foodDrive
            let neural = try brain.advance(milliseconds: milliseconds, input: world.neuralInput(),
                                            sensoryEnabled: before.sensoryEnabled,
                                            foodDrive: drive)
            let beforeRemaining = remainingFood()
            world.advance(neural: neural, input: raw, dt: Double(milliseconds) / 1000)
            simulatedMilliseconds += milliseconds
            tick += 1
            let time = Double(simulatedMilliseconds) / 1000
            let after = world.snapshot
            let afterRemaining = remainingFood()
            let consumed = max(0, beforeRemaining - afterRemaining)
            let pn = Double(neural.odorRelayLeftHz + neural.odorRelayRightHz)

            if phase == "firstFood" || phase == "settledFull" { firstFoodConsumed += consumed }
            if phase == "secondApproach" { secondFoodConsumed += consumed }
            if phase == "settledFull" {
                movementDuringFull += before.fly.position.distance(to: after.fly.position)
            }
            if raw.odorLeft + raw.odorRight > 0 {
                if drive > 0 { maxPNDuringHungry = max(maxPNDuringHungry, pn) }
                if phase == "settledFull", let full = firstFullTime, time - full >= 2 {
                    maxPNDuringSettledFull = max(maxPNDuringSettledFull, pn)
                }
            }

            if phase == "firstFood", !after.body.isFoodMotivated {
                firstFullTime = time
                phase = "settledFull"
                milestones.append(milestone("firstFoodFull", time))
            } else if phase == "settledFull", let full = firstFullTime, time - full >= 5 {
                firstFoodRemainingAtClear = afterRemaining
                let bodyBeforeClear = after.body
                world.perform(.clearFood)
                clearFoodBodyUnchanged = bodyBeforeClear == world.snapshot.body
                clearTime = time
                phase = "recovering"
                milestones.append(milestone("firstFoodClearedAfterFull", time))
            } else if phase == "recovering", after.body.isFoodMotivated {
                let center = Point2(x: width * 0.5, y: height * 0.5)
                let delta = Point2(x: center.x - after.fly.position.x,
                                   y: center.y - after.fly.position.y)
                let length = max(0.001, hypot(delta.x, delta.y))
                let target = Point2(x: after.fly.position.x + delta.x / length * 120,
                                    y: after.fly.position.y + delta.y / length * 120)
                world.perform(.placeFood(target))
                secondPosition = target
                secondPlacementTime = time
                phase = "secondApproach"
                milestones.append(milestone("secondFoodPlacedAfterRecovery", time))
            } else if phase == "secondApproach", secondFoodConsumed > 0,
                      !after.body.isFoodMotivated {
                secondFullTime = time
                phase = "complete"
                milestones.append(milestone("secondFoodFull", time))
            }

            if tick % 300 == 0 || phase == "complete" {
                trace.append(["timeSeconds": time, "phase": phase,
                              "hunger": after.body.hunger, "foodDrive": after.body.foodDrive,
                              "position": point(after.fly.position),
                              "activity": after.fly.activity.rawValue,
                              "remainingFood": remainingFood(), "pnTotalHz": pn])
            }
        }

        let report: [String: Any] = [
            "schemaVersion": 1, "brainModel": brain.modelID, "seed": seed, "modelSeconds": Double(simulatedMilliseconds) / 1000,
            "world": ["width": width, "height": height],
            "initialHunger": 0.65, "initialFoodMotivated": true,
            "firstFoodPosition": point(firstPosition),
            "secondFoodPosition": secondPosition.map(point) ?? NSNull(),
            "milestones": milestones, "sparseTrace": trace,
            "totalConsumed": world.snapshot.body.consumedFood,
            "finalHunger": world.snapshot.body.hunger,
            "firstFoodConsumed": firstFoodConsumed,
            "secondFoodConsumed": secondFoodConsumed,
            "firstFoodRemainingAtClear": firstFoodRemainingAtClear,
            "maxPNDuringHungry": maxPNDuringHungry,
            "maxPNDuringSettledFull": maxPNDuringSettledFull,
            "movementDuringFullPixels": movementDuringFull,
            "recoveryDurationSeconds": (clearTime != nil && secondPlacementTime != nil) ? secondPlacementTime! - clearTime! : 0,
            "secondMealCompletionSeconds": (secondPlacementTime != nil && secondFullTime != nil) ? secondFullTime! - secondPlacementTime! : 0,
            "clearFoodBodyUnchanged": clearFoodBodyUnchanged,
            "cyclesCompleted": phase == "complete",
            "brainReceivesCoordinates": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
