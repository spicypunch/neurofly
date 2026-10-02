import Darwin
import Foundation
import Metal

private struct BrainStepParams {
    var n: UInt32
    var slot: UInt32
    var stepIndex: UInt32
    var curSlot: UInt32
    var inhSlot: UInt32
    var seed: UInt32
    var refractory: UInt32
    var invFx: Float
    var decay: Float
    var threshold: Float
    var pNoise: Float
    var noiseKick: Float
    var activityScale: Float
    var odorLeft: Float
    var odorRight: Float
    var taste: Float
    var loomingLeft: Float
    var loomingRight: Float
    var touch: Float
}

private enum BrainGroup {
    static let turnLeft = 1
    static let turnRight = 2
    static let forward = 3
    static let escape = 4
    static let feeding = 5
    static let grooming = 6
    static let odorRelayLeft = 7
    static let odorRelayRight = 8
    static let flightLeft = 9
    static let flightRight = 10
    static let slots = 12 // two relay and two flight readouts plus padding
}

private let baselineSalt: UInt32 = 0x51ED_2701

// Published Shiu et al. sugar assay IDs that are present in the shipped
// FlyWire v783 artifact. These are data selectors, not inferred cell-type
// names; one older sugar ID is absent from v783 and is intentionally omitted.
private let sugarGRNRootIDs: Set<UInt64> = [
    720575940624963786, 720575940630233916, 720575940637568838,
    720575940638202345, 720575940617000768, 720575940630797113,
    720575940632889389, 720575940621754367, 720575940621502051,
    720575940640649691, 720575940639332736, 720575940616885538,
    720575940639198653, 720575940617937543, 720575940632425919,
    720575940633143833, 720575940612670570, 720575940628853239,
    720575940629176663, 720575940611875570,
]
private let feedingReadoutRootIDs: Set<UInt64> = [
    720575940660219265, // CB0701, right MN9 correspondence
    720575940618238523, // CB0701, left MN9 correspondence
]
private let odorRelayRootIDs: Set<UInt64> = [
    720575940630770042, // DM1_lPN, left
    720575940619071005, // DM1_lPN, right
]

@inline(__always)
private func pcgHash(_ value: UInt32) -> UInt32 {
    let state = value &* 747_796_405 &+ 2_891_336_453
    let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277_803_737
    return (word >> 22) ^ word
}

@inline(__always)
private func pcgUnit(_ value: UInt32) -> Float {
    Float(value >> 8) * 5.9604645e-8
}

@inline(__always)
private func pcgDraw(_ seed: UInt32, _ salt: UInt32, _ index: UInt32) -> Float {
    pcgUnit(pcgHash(pcgHash(seed &+ salt) &+ index))
}

private struct BrainTuning {
    let decay: Float = 0.95122945 // exp(-1/20 ms), fixed 1 ms integration step
    let threshold: Float = 1
    let refractoryMs: UInt32 = 2
    let floorV: Float = -2
    let weightScale: Float = 0.0032
    let modScale: Float = 0.5
    let gapJunctionBoost: Float = 0.5
    let sensoryGFBoost: Float = 1.5
    let gfInputScale: Float = 0.12
    let inhibitoryDelayMs: Int = 4
    let pNoise: Float = 0.005
    let noiseKick: Float = 0.25
    let rateAlpha: Float = 1.0 / 120.0
}

/// A whole-graph Metal LIF simulation. The class is intentionally internal;
/// `BrainEngine` owns its serial access and exposes only the stable public API.
final class MetalBrainSimulation {
    let neuronCount: Int
    let edgeCount: Int
    let gpuName: String
    let mappingSummary: [String: String]

    private let connectome: LoadedConnectome
    private let tuning = BrainTuning()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let updatePipeline: MTLComputePipelineState
    private let propagatePipeline: MTLComputePipelineState
    private let fixedPointScale: Float
    private let ringSlots: Int
    private let maxBatch = 64

    // Immutable graph buffers.
    private let rowStartBuffer: MTLBuffer
    private let colIdxBuffer: MTLBuffer
    private let weightBuffer: MTLBuffer

    // Per-neuron and per-batch state.
    private let voltageBuffer: MTLBuffer
    private let refractoryBuffer: MTLBuffer
    private let baselineBuffer: MTLBuffer
    private let inputKindBuffer: MTLBuffer
    private let groupBuffer: MTLBuffer
    private let externalInputBuffer: MTLBuffer
    private let excitationBuffer: MTLBuffer
    private let inhibitionBuffer: MTLBuffer
    private let spikeListBuffer: MTLBuffer
    private let spikeCountBuffer: MTLBuffer
    private let groupCountBuffer: MTLBuffer

    private let baselinePointer: UnsafeMutablePointer<Float>
    private let spikeCountPointer: UnsafeMutablePointer<UInt32>
    private let groupCountPointer: UnsafeMutablePointer<UInt32>

    private let neuronThreads: MTLSize
    private let neuronGrid: MTLSize
    private let propagationThreads: MTLSize
    private let propagationGrid: MTLSize

    private let groupSizes: [Float]
    private let sensoryKinds: [UInt8]
    private let groupOf: [UInt8]
    private let classOf: [UInt8]
    private let roleOf: [String]
    private let classRanges: [ClosedRange<Float>]

    private var seed: UInt32
    private(set) var simulatedMilliseconds = 0
    private var rates = [Float](repeating: 0, count: BrainGroup.slots)
    private var populationRate: Float = 0
    private(set) var lastComputationMilliseconds: Double = 0

    init(connectome: LoadedConnectome, seed: UInt32) throws {
        self.connectome = connectome
        neuronCount = connectome.neuronCount
        edgeCount = connectome.edgeCount
        self.seed = seed
        ringSlots = tuning.inhibitoryDelayMs + 1

        guard MemoryLayout<BrainStepParams>.stride == 76 else {
            throw BrainEngineError.invalidData("host Metal parameter layout is not 76 bytes")
        }
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw BrainEngineError.metalUnavailable("no default Metal device")
        }
        guard let queue = metalDevice.makeCommandQueue() else {
            throw BrainEngineError.metalUnavailable("could not create a Metal command queue")
        }
        device = metalDevice
        gpuName = metalDevice.name
        commandQueue = queue

        // A packaged .app owns its kernel directly under Contents/Resources;
        // check that location before touching SwiftPM's generated Bundle.module
        // accessor. The latter is retained for tests and `swift run`, but its
        // generated accessor can trap if a copied app has no build-directory
        // resource bundle to fall back to.
        let sourceURL: URL? = {
            let fileManager = FileManager.default
            if let appKernel = Bundle.main.resourceURL?.appendingPathComponent("LIF.metal"),
               fileManager.fileExists(atPath: appKernel.path) {
                return appKernel
            }
            // Do not evaluate Bundle.module for a copied app whose resources
            // are incomplete: SwiftPM's generated accessor may fatalError when
            // its build-directory fallback is absent. The throwing initializer
            // below can report this as a normal unavailable-resource error.
            if Bundle.main.bundleURL.pathExtension == "app" {
                return nil
            }
            if let moduleKernel = Bundle.module.url(forResource: "LIF", withExtension: "metal"),
               fileManager.fileExists(atPath: moduleKernel.path) {
                return moduleKernel
            }
            if let nestedKernel = Bundle.module.url(forResource: "LIF", withExtension: "metal",
                                                    subdirectory: "Resources"),
               fileManager.fileExists(atPath: nestedKernel.path) {
                return nestedKernel
            }
            return nil
        }()
        guard let sourceURL,
              let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            throw BrainEngineError.metalUnavailable("LIF.metal is missing from Bundle.module")
        }
        let compileOptions = MTLCompileOptions()
        compileOptions.mathMode = .safe
        let library: MTLLibrary
        do {
            library = try metalDevice.makeLibrary(source: source, options: compileOptions)
        } catch {
            throw BrainEngineError.metalUnavailable("LIF.metal failed to compile: \(error)")
        }
        guard let updateFunction = library.makeFunction(name: "lif_update"),
              let propagateFunction = library.makeFunction(name: "lif_propagate") else {
            throw BrainEngineError.metalUnavailable("LIF.metal is missing its two kernels")
        }
        do {
            updatePipeline = try metalDevice.makeComputePipelineState(function: updateFunction)
            propagatePipeline = try metalDevice.makeComputePipelineState(function: propagateFunction)
        } catch {
            throw BrainEngineError.metalUnavailable("could not build LIF pipelines: \(error)")
        }

        let n = connectome.neuronCount
        let e = connectome.edgeCount
        guard let rowBuffer = connectome.rowStart.withUnsafeBytes({ raw in
            metalDevice.makeBuffer(bytes: raw.baseAddress!, length: (n + 1) * 4,
                                   options: .storageModeShared)
        }) else {
            throw BrainEngineError.metalUnavailable("could not allocate rowStart buffer")
        }
        guard let colBuffer = connectome.colIdxData.withUnsafeBytes({ raw in
            metalDevice.makeBuffer(bytes: raw.baseAddress!, length: e * 4,
                                   options: .storageModeShared)
        }) else {
            throw BrainEngineError.metalUnavailable("could not allocate colIdx buffer")
        }
        guard let weights = metalDevice.makeBuffer(length: e * 4, options: .storageModeShared) else {
            throw BrainEngineError.metalUnavailable("could not allocate weight buffer")
        }
        rowStartBuffer = rowBuffer
        colIdxBuffer = colBuffer
        weightBuffer = weights
        fixedPointScale = try Self.buildWeights(connectome: connectome, tuning: tuning,
                                                 into: weights)

        let roleNames = connectome.roleNames
        let roleFor = connectome.role.map { roleNames[Int($0)] }
        roleOf = roleFor
        classOf = connectome.superClass
        let classRanges = connectome.superClassNames.map { name -> ClosedRange<Float> in
            switch name {
            case "optic", "visual_projection": return 0.021...0.043
            case "central": return 0.023...0.047
            case "visual_centrifugal", "descending", "ascending", "motor", "endocrine":
                return 0.019...0.043
            case "sensory", "sensory_ascending": return 0.000...0.006
            default: return 0.019...0.043
            }
        }
        self.classRanges = classRanges

        let mapping = try Self.makeMapping(connectome: connectome)
        mappingSummary = mapping.summary
        sensoryKinds = mapping.sensoryKinds
        groupOf = mapping.groupOf
        groupSizes = mapping.groupSizes
        let inputKinds = mapping.sensoryKinds
        let groups = mapping.groupOf

        func makeBuffer<T>(for values: [T]) -> MTLBuffer? {
            values.withUnsafeBytes { raw in
                metalDevice.makeBuffer(bytes: raw.baseAddress!, length: raw.count,
                                       options: .storageModeShared)
            }
        }
        guard let inputBuffer = makeBuffer(for: inputKinds),
              let groupBuffer = makeBuffer(for: groups),
              let voltage = metalDevice.makeBuffer(length: n * 4, options: .storageModeShared),
              let refractory = metalDevice.makeBuffer(length: n, options: .storageModeShared),
              let baseline = metalDevice.makeBuffer(length: n * 4, options: .storageModeShared),
              let external = metalDevice.makeBuffer(length: n * 4, options: .storageModeShared),
              let excitation = metalDevice.makeBuffer(length: n * 4, options: .storageModeShared),
              let inhibition = metalDevice.makeBuffer(length: n * 4 * ringSlots, options: .storageModeShared),
              let spikeList = metalDevice.makeBuffer(length: n * 4, options: .storageModeShared),
              let spikeCount = metalDevice.makeBuffer(length: maxBatch * 4, options: .storageModeShared),
              let groupCount = metalDevice.makeBuffer(length: maxBatch * BrainGroup.slots * 4,
                                                       options: .storageModeShared) else {
            throw BrainEngineError.metalUnavailable("could not allocate per-neuron buffers")
        }
        inputKindBuffer = inputBuffer
        self.groupBuffer = groupBuffer
        voltageBuffer = voltage
        refractoryBuffer = refractory
        baselineBuffer = baseline
        externalInputBuffer = external
        excitationBuffer = excitation
        inhibitionBuffer = inhibition
        spikeListBuffer = spikeList
        spikeCountBuffer = spikeCount
        groupCountBuffer = groupCount
        baselinePointer = baseline.contents().bindMemory(to: Float.self, capacity: n)
        spikeCountPointer = spikeCount.contents().bindMemory(to: UInt32.self, capacity: maxBatch)
        groupCountPointer = groupCount.contents().bindMemory(to: UInt32.self,
                                                              capacity: maxBatch * BrainGroup.slots)

        memset(voltage.contents(), 0, voltage.length)
        memset(refractory.contents(), 0, refractory.length)
        memset(external.contents(), 0, external.length)
        memset(excitation.contents(), 0, excitation.length)
        memset(inhibition.contents(), 0, inhibition.length)
        memset(spikeList.contents(), 0, spikeList.length)
        memset(spikeCount.contents(), 0, spikeCount.length)
        memset(groupCount.contents(), 0, groupCount.length)

        let updateWidth = max(1, min(256, updatePipeline.maxTotalThreadsPerThreadgroup))
        neuronThreads = MTLSize(width: updateWidth, height: 1, depth: 1)
        neuronGrid = MTLSize(width: n, height: 1, depth: 1)
        let propagateWidth = max(1, min(32, propagatePipeline.maxTotalThreadsPerThreadgroup))
        propagationThreads = MTLSize(width: propagateWidth, height: 1, depth: 1)
        propagationGrid = MTLSize(width: 1024, height: 1, depth: 1)

        applySeed(seed)
    }

    private struct Mapping {
        let sensoryKinds: [UInt8]
        let groupOf: [UInt8]
        let groupSizes: [Float]
        let summary: [String: String]
    }

    private static func makeMapping(connectome c: LoadedConnectome) throws -> Mapping {
        let n = c.neuronCount
        let names = c.cellTypeName
        let roles = c.roleName
        let sideLeft = c.sideNames.firstIndex(of: "left").map(UInt8.init) ?? 1
        let sideRight = c.sideNames.firstIndex(of: "right").map(UInt8.init) ?? 2

        func byRole(_ namesToFind: Set<String>, side: UInt8? = nil) -> [Int] {
            c.role.indices.filter { namesToFind.contains(roles[$0]) &&
                (side == nil || c.side[$0] == side!) }
        }
        func byType(_ predicate: (String) -> Bool, side: UInt8? = nil) -> [Int] {
            names.indices.filter { predicate(names[$0]) &&
                (side == nil || c.side[$0] == side!) }
        }

        // DM1 is a concrete, bilateral ORN channel in the supplied artifact.
        // The external drive stops at these ORNs; the DM1 projection neurons
        // below are observed as relays after the graph propagates the spikes.
        let odorLeft = byType({ $0.lowercased() == "orn_dm1" }, side: sideLeft)
        let odorRight = byType({ $0.lowercased() == "orn_dm1" }, side: sideRight)
        let odorAll = odorLeft + odorRight
        let odorRelays = c.rootId.indices.filter { odorRelayRootIDs.contains(c.rootId[$0]) }
        let taste = c.rootId.indices.filter { sugarGRNRootIDs.contains(c.rootId[$0]) }
        let feeding = c.rootId.indices.filter { feedingReadoutRootIDs.contains(c.rootId[$0]) }
        let loomingLeft = byRole(["lc4", "lplc2"], side: sideLeft)
        let loomingRight = byRole(["lc4", "lplc2"], side: sideRight)
        let touch = byRole(["sens"])
        guard odorAll.count > 0, odorLeft.count > 0, odorRight.count > 0,
              odorRelays.count == odorRelayRootIDs.count,
              taste.count == sugarGRNRootIDs.count,
              feeding.count == feedingReadoutRootIDs.count,
              !touch.isEmpty, !loomingLeft.isEmpty || !loomingRight.isEmpty else {
            throw BrainEngineError.invalidData(
                "shipped sensory/readout root IDs or bilateral ORN_DM1 mapping are incomplete")
        }
        guard taste.allSatisfy({ c.superClassNames[Int(c.superClass[$0])] == "sensory" }) else {
            throw BrainEngineError.invalidData("published sugar GRN IDs are not sensory neurons in this artifact")
        }

        var sensory = [UInt8](repeating: 0, count: n)
        func assign(_ indices: [Int], _ kind: UInt8) throws {
            for index in indices {
                guard index >= 0, index < n else {
                    throw BrainEngineError.invalidData("sensory mapping index is out of range")
                }
                guard sensory[index] == 0 || sensory[index] == kind else {
                    throw BrainEngineError.invalidData("sensory channels overlap at neuron \(index)")
                }
                sensory[index] = kind
            }
        }
        let leftOdor = odorLeft
        let rightOdor = odorRight
        try assign(leftOdor, 1)
        try assign(rightOdor, 2)
        try assign(taste, 3)
        try assign(loomingLeft, 4)
        try assign(loomingRight, 5)
        try assign(touch, 6)

        var groups = [UInt8](repeating: 0, count: n)
        let roleTurnLeft = byRole(["dna01", "dna02"], side: sideLeft)
        let roleTurnRight = byRole(["dna01", "dna02"], side: sideRight)
        let roleForward = byRole(["dnp09"])
        let roleEscape = byRole(["gf"])
        let roleGrooming = byRole(["dng11"])
        let flightLeft = byType({ $0.lowercased().hasPrefix("dng02_") }, side: sideLeft)
        let flightRight = byType({ $0.lowercased().hasPrefix("dng02_") }, side: sideRight)

        // The v783 annotation names the two published MN9 correspondence
        // neurons as CB0701, so root IDs are the stable selector here.
        let roleFeeding = feeding
        let allOutputSets = roleTurnLeft + roleTurnRight + roleForward + roleEscape + roleGrooming +
            roleFeeding + odorRelays + flightLeft + flightRight
        guard Set(allOutputSets).isDisjoint(with: Set(sensory.enumerated().compactMap { $0.element == 0 ? nil : $0.offset })) else {
            throw BrainEngineError.invalidData("a sensory input target is also a motor readout")
        }

        func assignGroup(_ indices: [Int], _ group: UInt8) throws {
            for index in indices {
                guard groups[index] == 0 else {
                    throw BrainEngineError.invalidData("motor readout groups overlap at neuron \(index)")
                }
                groups[index] = group
            }
        }
        try assignGroup(roleTurnLeft, UInt8(BrainGroup.turnLeft))
        try assignGroup(roleTurnRight, UInt8(BrainGroup.turnRight))
        try assignGroup(roleForward, UInt8(BrainGroup.forward))
        try assignGroup(roleEscape, UInt8(BrainGroup.escape))
        try assignGroup(roleFeeding, UInt8(BrainGroup.feeding))
        try assignGroup(roleGrooming, UInt8(BrainGroup.grooming))
        guard let odorRelayLeft = odorRelays.first(where: { c.rootId[$0] == 720575940630770042 }),
              let odorRelayRight = odorRelays.first(where: { c.rootId[$0] == 720575940619071005 }) else {
            throw BrainEngineError.invalidData("DM1_lPN relay IDs disappeared during mapping")
        }
        try assignGroup([odorRelayLeft], UInt8(BrainGroup.odorRelayLeft))
        try assignGroup([odorRelayRight], UInt8(BrainGroup.odorRelayRight))
        try assignGroup(flightLeft, UInt8(BrainGroup.flightLeft))
        try assignGroup(flightRight, UInt8(BrainGroup.flightRight))

        let groupSizes = (1...10).map { id in
            Float(max(1, groups.reduce(into: 0) { if Int($1) == id { $0 += 1 } }))
        }
        let summary: [String: String] = [
            "odorLeft": "\(leftOdor.count) ORN_DM1 neurons with left-side annotations (kind 1)",
            "odorRight": "\(rightOdor.count) ORN_DM1 neurons with right-side annotations (kind 2)",
            "odorRelay": "DM1_lPN root IDs observed: left 1, right 1; relay groups are read after graph propagation",
            "flightCandidate": "DNg02_a..h candidate flight readout: left \(flightLeft.count), right \(flightRight.count); diagnostic only",
            "taste": "\(taste.count) published sugar GRN root IDs (kind 3)",
            "loomingLeft": "\(loomingLeft.count) LC4/LPLC2 role neurons on the left (kind 4)",
            "loomingRight": "\(loomingRight.count) LC4/LPLC2 role neurons on the right (kind 5)",
            "touch": "\(touch.count) annotated sensory role neurons (kind 6)",
            "turnLeft": "DNa01/DNa02 left: \(roleTurnLeft.count)",
            "turnRight": "DNa01/DNa02 right: \(roleTurnRight.count)",
            "forward": "DNp09: \(roleForward.count)",
            "escape": "DNp01/GF role: \(roleEscape.count)",
            "feeding": "CB0701 MN9 correspondence root IDs: \(roleFeeding.count)",
            "grooming": "DNg11: \(roleGrooming.count)",
            "model": "Fixed-step LIF with explicit engineered baseline/noise/gain parameters; no hunger, learning, or memory",
            "inputContract": "External channels are assigned only to sensory receptor/pathway neurons; command neurons receive graph drive",
        ]
        return Mapping(sensoryKinds: sensory, groupOf: groups,
                       groupSizes: groupSizes, summary: summary)
    }

    private static func buildWeights(connectome c: LoadedConnectome,
                                     tuning p: BrainTuning,
                                     into output: MTLBuffer) throws -> Float {
        let e = c.edgeCount
        let n = c.neuronCount
        var maxAbs: Float = 0
        c.colIdxData.withUnsafeBytes { colRaw in
            c.weightData.withUnsafeBytes { weightRaw in
                for source in 0..<n {
                    let modulatory = c.modulatoryNts.contains(c.ntNames[Int(c.nt[source])])
                    let rowGain = p.weightScale * (modulatory ? p.modScale : 1)
                    for edge in Int(c.rowStart[source])..<Int(c.rowStart[source + 1]) {
                        let target = Int(colRaw.loadUnaligned(fromByteOffset: edge * 4, as: UInt32.self))
                        let targetRole = c.roleNames[Int(c.role[target])]
                        let sourceRole = c.roleNames[Int(c.role[source])]
                        let gfGain: Float
                        if targetRole == "gf" {
                            if sourceRole == "lc4" || sourceRole == "lplc2" {
                                gfGain = p.gapJunctionBoost
                            } else if sourceRole == "sens" {
                                gfGain = p.sensoryGFBoost
                            } else {
                                gfGain = p.gfInputScale
                            }
                        } else {
                            gfGain = 1
                        }
                        let weight = Float(abs(Int(weightRaw.loadUnaligned(fromByteOffset: edge * 2,
                                                                           as: Int16.self))))
                        maxAbs = max(maxAbs, weight * rowGain * gfGain)
                    }
                }
            }
        }
        var scale: Float = 1_048_576
        while scale > 65_536 && Double(maxAbs) * Double(scale) * 4096 > Double(Int32.max) {
            scale /= 2
        }
        guard Double(maxAbs) * Double(scale) * 4096 <= Double(Int32.max) else {
            throw BrainEngineError.invalidData("quantized edge weights overflow Int32")
        }
        let outputPointer = output.contents().bindMemory(to: Int32.self, capacity: e)
        c.colIdxData.withUnsafeBytes { colRaw in
            c.weightData.withUnsafeBytes { weightRaw in
                for source in 0..<n {
                    let modulatory = c.modulatoryNts.contains(c.ntNames[Int(c.nt[source])])
                    let rowGain = p.weightScale * (modulatory ? p.modScale : 1)
                    for edge in Int(c.rowStart[source])..<Int(c.rowStart[source + 1]) {
                        let target = Int(colRaw.loadUnaligned(fromByteOffset: edge * 4, as: UInt32.self))
                        let targetRole = c.roleNames[Int(c.role[target])]
                        let sourceRole = c.roleNames[Int(c.role[source])]
                        let gfGain: Float
                        if targetRole == "gf" {
                            if sourceRole == "lc4" || sourceRole == "lplc2" {
                                gfGain = p.gapJunctionBoost
                            } else if sourceRole == "sens" {
                                gfGain = p.sensoryGFBoost
                            } else {
                                gfGain = p.gfInputScale
                            }
                        } else {
                            gfGain = 1
                        }
                        let rawWeight = Float(weightRaw.loadUnaligned(fromByteOffset: edge * 2, as: Int16.self))
                        outputPointer[edge] = Int32((rawWeight * rowGain * gfGain * scale).rounded())
                    }
                }
            }
        }
        return scale
    }

    private func applySeed(_ value: UInt32) {
        seed = value
        let roleNames = connectome.roleNames
        for i in 0..<neuronCount {
            let role = roleNames[Int(connectome.role[i])]
            if sensoryKinds[i] != 0 {
                baselinePointer[i] = 0
            } else if role == "gf" {
                baselinePointer[i] = 0.002
            } else if role == "dnp09" {
                baselinePointer[i] = 0.032
            } else if role == "dna01" || role == "dna02" || role == "dng11" ||
                        role == "mdn" || role == "escw" || groupOf[i] == UInt8(BrainGroup.feeding) {
                baselinePointer[i] = 0.022
            } else {
                let range = classRanges[Int(classOf[i])]
                baselinePointer[i] = range.lowerBound +
                    (range.upperBound - range.lowerBound) * pcgDraw(value, baselineSalt, UInt32(i))
            }
        }
    }

    func reset(seed: UInt32) throws {
        self.seed = seed
        simulatedMilliseconds = 0
        rates = [Float](repeating: 0, count: BrainGroup.slots)
        populationRate = 0
        lastComputationMilliseconds = 0
        memset(voltageBuffer.contents(), 0, voltageBuffer.length)
        memset(refractoryBuffer.contents(), 0, refractoryBuffer.length)
        memset(externalInputBuffer.contents(), 0, externalInputBuffer.length)
        memset(excitationBuffer.contents(), 0, excitationBuffer.length)
        memset(inhibitionBuffer.contents(), 0, inhibitionBuffer.length)
        memset(spikeCountBuffer.contents(), 0, spikeCountBuffer.length)
        memset(groupCountBuffer.contents(), 0, groupCountBuffer.length)
        applySeed(seed)
    }

    func advance(milliseconds: Int, input: SensoryInput, sensoryEnabled: Bool) throws -> NeuralReadout {
        guard milliseconds >= 0 else {
            throw BrainEngineError.invalidArgument("milliseconds must be non-negative")
        }
        if milliseconds == 0 {
            return currentReadout()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let safeInput = Self.sanitize(input, enabled: sensoryEnabled)
        var remaining = milliseconds
        while remaining > 0 {
            let batch = min(remaining, maxBatch)
            try runBatch(batch, input: safeInput)
            remaining -= batch
        }
        lastComputationMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return currentReadout()
    }

    private static func sanitize(_ input: SensoryInput, enabled: Bool) -> [Float] {
        guard enabled else { return [0, 0, 0, 0, 0, 0] }
        func clean(_ value: Float) -> Float {
            guard value.isFinite else { return 0 }
            return min(1, max(0, value))
        }
        // Gains are explicit model parameters. They make a 0...1 receptor level
        // readable by the LIF threshold; they are not claims about in-vivo units.
        // Engineered virtual-sensor adapter: recruit ORNs for weak odors, and
        // amplify bilateral contrast before it is lost in the two PN readouts'
        // strong common response. This is not a biological receptor model.
        // Only ORNs get this drive; PNs receive propagated graph spikes only.
        let odorLeft = clean(input.odorLeft), odorRight = clean(input.odorRight)
        let odorSum = odorLeft + odorRight
        let common = sqrt(odorSum * 0.5) * 0.22
        let contrast = max(-0.95, min(0.95, 10 * (odorLeft - odorRight) / max(0.02, odorSum)))
        return [min(0.22, common * (1 + contrast)),
                min(0.22, common * (1 - contrast)),
                clean(input.taste) * 0.30,
                clean(input.loomingLeft) * 0.34,
                clean(input.loomingRight) * 0.34,
                clean(input.touch) * 0.28]
    }

    private func runBatch(_ count: Int, input: [Float]) throws {
        guard count > 0, count <= maxBatch else {
            throw BrainEngineError.invalidArgument("invalid Metal batch size")
        }
        var parameters = [BrainStepParams]()
        parameters.reserveCapacity(count)
        let base = simulatedMilliseconds
        for slot in 0..<count {
            let step = base + slot + 1
            parameters.append(BrainStepParams(
                n: UInt32(neuronCount), slot: UInt32(slot), stepIndex: UInt32(truncatingIfNeeded: step),
                curSlot: UInt32((step - 1) % ringSlots),
                inhSlot: UInt32((step - 1 + tuning.inhibitoryDelayMs) % ringSlots),
                seed: seed, refractory: tuning.refractoryMs,
                invFx: 1 / fixedPointScale, decay: tuning.decay, threshold: tuning.threshold,
                pNoise: tuning.pNoise, noiseKick: tuning.noiseKick, activityScale: 1,
                odorLeft: input[0], odorRight: input[1], taste: input[2],
                loomingLeft: input[3], loomingRight: input[4], touch: input[5]))
        }
        memset(spikeCountBuffer.contents(), 0, count * 4)
        memset(groupCountBuffer.contents(), 0, count * BrainGroup.slots * 4)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BrainEngineError.metalFailure("could not create a command buffer")
        }
        encoder.setBuffer(voltageBuffer, offset: 0, index: 0)
        encoder.setBuffer(refractoryBuffer, offset: 0, index: 1)
        encoder.setBuffer(baselineBuffer, offset: 0, index: 2)
        encoder.setBuffer(inputKindBuffer, offset: 0, index: 3)
        encoder.setBuffer(groupBuffer, offset: 0, index: 4)
        encoder.setBuffer(externalInputBuffer, offset: 0, index: 5)
        encoder.setBuffer(excitationBuffer, offset: 0, index: 6)
        encoder.setBuffer(inhibitionBuffer, offset: 0, index: 7)
        encoder.setBuffer(spikeListBuffer, offset: 0, index: 8)
        encoder.setBuffer(spikeCountBuffer, offset: 0, index: 9)
        encoder.setBuffer(groupCountBuffer, offset: 0, index: 10)
        encoder.setBuffer(rowStartBuffer, offset: 0, index: 12)
        encoder.setBuffer(colIdxBuffer, offset: 0, index: 13)
        encoder.setBuffer(weightBuffer, offset: 0, index: 14)
        for parameter in parameters {
            var p = parameter
            encoder.setComputePipelineState(updatePipeline)
            encoder.setBytes(&p, length: MemoryLayout<BrainStepParams>.stride, index: 11)
            encoder.dispatchThreads(neuronGrid, threadsPerThreadgroup: neuronThreads)
            encoder.setComputePipelineState(propagatePipeline)
            encoder.setBytes(&p, length: MemoryLayout<BrainStepParams>.stride, index: 11)
            encoder.dispatchThreadgroups(propagationGrid, threadsPerThreadgroup: propagationThreads)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw BrainEngineError.metalFailure(commandBuffer.error?.localizedDescription ?? "command buffer did not complete")
        }

        let groupPointer = groupCountPointer
        for slot in 0..<count {
            let total = Float(spikeCountPointer[slot])
            for group in 0..<10 {
                let spikes = Float(groupPointer[slot * BrainGroup.slots + group])
                let instantaneous = spikes * 1000 / groupSizes[group]
                rates[group] += (instantaneous - rates[group]) * tuning.rateAlpha
            }
            let populationInstantaneous = total * 1000 / Float(neuronCount)
            populationRate += (populationInstantaneous - populationRate) * tuning.rateAlpha
        }
        simulatedMilliseconds += count
    }

    private func currentReadout() -> NeuralReadout {
        NeuralReadout(turnLeftHz: rates[BrainGroup.turnLeft - 1],
                      turnRightHz: rates[BrainGroup.turnRight - 1],
                      forwardHz: rates[BrainGroup.forward - 1],
                      escapeHz: rates[BrainGroup.escape - 1],
                      feedingHz: rates[BrainGroup.feeding - 1],
                      groomingHz: rates[BrainGroup.grooming - 1],
                      odorRelayLeftHz: rates[BrainGroup.odorRelayLeft - 1],
                      odorRelayRightHz: rates[BrainGroup.odorRelayRight - 1],
                      populationHz: populationRate,
                      simulatedMilliseconds: simulatedMilliseconds,
                      computationMilliseconds: lastComputationMilliseconds)
    }

    func diagnosticRates() -> [String: Float] {
        [
            "odorRelayLeftHz": rates[BrainGroup.odorRelayLeft - 1],
            "odorRelayRightHz": rates[BrainGroup.odorRelayRight - 1],
            "flightCandidateLeftHz": rates[BrainGroup.flightLeft - 1],
            "flightCandidateRightHz": rates[BrainGroup.flightRight - 1],
        ]
    }
}
