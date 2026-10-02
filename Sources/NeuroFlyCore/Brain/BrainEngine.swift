import Foundation

/// Public entry point for the real FlyWire-derived neural simulation.
///
/// Calls are serialized on one private queue. This keeps Metal resources and
/// the fixed-step state single-owner while allowing the UI/world to call the
/// synchronous API from whichever thread owns its update loop.
public final class BrainEngine {
    public let neuronCount: Int
    public let edgeCount: Int
    public let gpuName: String
    public let mappingSummary: [String: String]

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let state: MetalBrainSimulation

    public init(dataDirectory: URL, seed: UInt32 = 42) throws {
        let loaded = try loadConnectome(dataDirectory: dataDirectory)
        let simulation = try MetalBrainSimulation(connectome: loaded, seed: seed)
        state = simulation
        neuronCount = simulation.neuronCount
        edgeCount = simulation.edgeCount
        gpuName = simulation.gpuName
        mappingSummary = simulation.mappingSummary

        let serialQueue = DispatchQueue(label: "com.neurofly.brain.serial",
                                         qos: .userInitiated)
        queue = serialQueue
        serialQueue.setSpecific(key: queueKey, value: 1)
    }

    /// Advances the connectome by a fixed number of one-millisecond steps.
    /// `sensoryEnabled` gates the six receptor drives; spontaneous/background
    /// network activity remains governed by the explicit model baseline/noise.
    /// `foodDrive` is an engineered body-state gain on odor and taste only.
    /// Raw sensory values and threat pathways are not changed by satiety.
    public func advance(milliseconds: Int,
                         input: SensoryInput,
                         sensoryEnabled: Bool = true,
                         foodDrive: Float = 1) throws -> NeuralReadout {
        try sync {
            try state.advance(milliseconds: milliseconds, input: input,
                              sensoryEnabled: sensoryEnabled, foodDrive: foodDrive)
        }
    }

    /// Clears membrane, refractory, delay-ring, and rate state and reseeds the
    /// deterministic baseline/noise streams.
    public func reset(seed: UInt32 = 42) throws {
        try sync {
            try state.reset(seed: seed)
        }
    }

    /// Optional instrumentation for experiments. These values are not used by
    /// the continuous motor decoder; they make the ORN→DM1_lPN and DNg02
    /// candidate paths inspectable without exposing graph state or coordinates.
    public func diagnosticRates() throws -> [String: Float] {
        try sync { state.diagnosticRates() }
    }

    private func sync<T>(_ body: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}
