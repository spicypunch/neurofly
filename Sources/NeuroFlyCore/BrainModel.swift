import Foundation

/// Real connectome datasets supported by NeuroFly.
///
/// `flywireV783` is the shipped legacy graph. `maleCNS` is selected only when
/// a complete `malecns/connectome.json` and its validated binary arrays are
/// present; it never falls back to the FlyWire graph.
public enum BrainModel: String, Codable, CaseIterable, Sendable {
    case flywireV783 = "flywire-v783"
    case maleCNS = "malecns"

    public var displayName: String {
        switch self {
        case .flywireV783: return "FlyWire v783"
        case .maleCNS: return "Male CNS"
        }
    }

    /// Relative directory below the data root. The shipped FlyWire files live
    /// directly in `data/`; Male CNS files are expected under `data/malecns/`.
    public var dataSubdirectory: String {
        switch self {
        case .flywireV783: return ""
        case .maleCNS: return "malecns"
        }
    }
}
