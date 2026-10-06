import CryptoKit
import Foundation

/// Errors raised while loading a real connectome graph.
public enum BrainEngineError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case invalidArgument(String)
    case missingData(URL)
    case invalidData(String)
    case metalUnavailable(String)
    case metalFailure(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message): return message
        case .missingData(let url): return "NeuroFly data is missing: \(url.path)"
        case .invalidData(let message): return "NeuroFly data is invalid: \(message)"
        case .metalUnavailable(let message): return "NeuroFly Metal is unavailable: \(message)"
        case .metalFailure(let message): return "NeuroFly Metal failed: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// The manifest is deliberately decoded separately from the binary arrays. It
/// is the contract that makes the two large data files safe to use.
struct ConnectomeManifest: Decodable {
    struct FileInfo: Decodable {
        let bytes: Int
        let sha256: String
    }

    struct ArrayInfo: Decodable {
        let file: String
        let byteOffset: Int
        let dtype: String
        let count: Int
        let components: Int
    }

    struct StringTables: Decodable {
        let superClasses: [String]
        let sides: [String]
        let nts: [String]
        let roles: [String]
        let cellTypes: [String]
    }

    struct DatasetMetadata: Decodable {
        let id: String?
        let displayName: String?
        let version: String?
        let source: String?
    }

    /// Every ID must be present in the graph's `rootId` array. A dataset ETL
    /// may preserve source body IDs there when the source has no FlyWire root
    /// IDs; the loader still resolves all groups against one neuron table.
    /// Optional fields allow legacy FlyWire manifests to omit this section;
    /// once the section is present it is validated as a complete mapping.
    struct NeuralMapping: Decodable {
        let odorLeft: [UInt64]?
        let odorRight: [UInt64]?
        let odorRelayLeft: [UInt64]?
        let odorRelayRight: [UInt64]?
        let taste: [UInt64]?
        let loomingLeft: [UInt64]?
        let loomingRight: [UInt64]?
        let touch: [UInt64]?
        let turnLeft: [UInt64]?
        let turnRight: [UInt64]?
        let forward: [UInt64]?
        let escape: [UInt64]?
        let feeding: [UInt64]?
        let grooming: [UInt64]?
        let flightLeft: [UInt64]?
        let flightRight: [UInt64]?
    }

    let format: String
    let neuronCount: Int
    let edgeCount: Int
    let byteOrder: String
    let files: [String: FileInfo]
    let arrays: [String: ArrayInfo]
    let stringTables: StringTables
    let roleCounts: [String: Int]
    let modulatoryNts: [String]
    let dataset: DatasetMetadata?
    let neuralMapping: NeuralMapping?
}

/// Root-ID mapping resolved to validated neuron-array indices before Metal is
/// touched. This keeps dataset-specific identity out of the simulator's
/// heuristic legacy FlyWire mapper.
struct ValidatedNeuralMapping {
    let odorLeft: [Int]
    let odorRight: [Int]
    let odorRelayLeft: [Int]
    let odorRelayRight: [Int]
    let taste: [Int]
    let loomingLeft: [Int]
    let loomingRight: [Int]
    let touch: [Int]
    let turnLeft: [Int]
    let turnRight: [Int]
    let forward: [Int]
    let escape: [Int]
    let feeding: [Int]
    let grooming: [Int]
    let flightLeft: [Int]
    let flightRight: [Int]

    var groups: [(String, [Int])] {
        [
            ("odorLeft", odorLeft), ("odorRight", odorRight),
            ("odorRelayLeft", odorRelayLeft), ("odorRelayRight", odorRelayRight),
            ("taste", taste), ("loomingLeft", loomingLeft),
            ("loomingRight", loomingRight), ("touch", touch),
            ("turnLeft", turnLeft), ("turnRight", turnRight),
            ("forward", forward), ("escape", escape), ("feeding", feeding),
            ("grooming", grooming), ("flightLeft", flightLeft),
            ("flightRight", flightRight),
        ]
    }
}

/// Validated graph data. Edge arrays stay in `Data` so Metal can copy them
/// without making a second Swift integer array of roughly 120 MB.
struct LoadedConnectome {
    let neuronCount: Int
    let edgeCount: Int
    let superClass: [UInt8]
    let side: [UInt8]
    let nt: [UInt8]
    let role: [UInt8]
    let cellType: [UInt16]
    let rootId: [UInt64]
    let rowStart: [UInt32]
    let colIdxData: Data
    let weightData: Data
    let superClassNames: [String]
    let sideNames: [String]
    let ntNames: [String]
    let roleNames: [String]
    let cellTypeNames: [String]
    let modulatoryNts: Set<String>
    let modelID: String
    let modelName: String
    let datasetVersion: String?
    let datasetSource: String?
    let neuralMapping: ValidatedNeuralMapping?

    var cellTypeName: [String] {
        cellType.map { index in
            let i = Int(index)
            return i < cellTypeNames.count ? cellTypeNames[i] : ""
        }
    }

    var roleName: [String] {
        role.map { index in
            let i = Int(index)
            return i < roleNames.count ? roleNames[i] : ""
        }
    }
}

private let expectedDTypeBytes: [String: Int] = [
    "float32": 4,
    "uint8": 1,
    "uint16": 2,
    "uint32": 4,
    "int16": 2,
    "int32": 4,
    "uint64": 8,
]

private extension String {
    var isSafeRelativeFileName: Bool {
        guard !isEmpty,
              !hasPrefix("/"),
              !contains(".."),
              !contains("/") else { return false }
        return self == URL(fileURLWithPath: self).lastPathComponent
    }
}

private func hexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func checkedByteCount(_ count: Int, elementSize: Int) throws -> Int {
    guard count >= 0, elementSize > 0 else {
        throw BrainEngineError.invalidData("negative array count or element size")
    }
    let (bytes, overflow) = count.multipliedReportingOverflow(by: elementSize)
    guard !overflow else {
        throw BrainEngineError.invalidData("array byte count overflow")
    }
    return bytes
}

private func readArray<T>(_ info: ConnectomeManifest.ArrayInfo,
                          from files: [String: Data],
                          expectedDType: String,
                          expectedCount: Int? = nil,
                          expectedComponents: Int? = nil,
                          as: T.Type) throws -> [T] {
    guard info.dtype == expectedDType else {
        throw BrainEngineError.invalidData(
            "array has dtype \(info.dtype), expected \(expectedDType)")
    }
    guard expectedDTypeBytes[info.dtype] == MemoryLayout<T>.size else {
        throw BrainEngineError.invalidData("reader size mismatch for array")
    }
    guard info.components > 0,
          expectedComponents == nil || info.components == expectedComponents,
          info.count >= 0,
          expectedCount == nil || info.count == expectedCount else {
        throw BrainEngineError.invalidData("array has an unexpected shape")
    }
    guard let file = files[info.file] else {
        throw BrainEngineError.invalidData("array references missing file \(info.file)")
    }
    let bytes = try checkedByteCount(info.count, elementSize: MemoryLayout<T>.size)
    guard info.byteOffset >= 0,
          info.byteOffset <= file.count,
          bytes <= file.count - info.byteOffset else {
        throw BrainEngineError.invalidData("array \(info.file) runs past its file")
    }
    guard info.count % info.components == 0 else {
        throw BrainEngineError.invalidData("array component count does not divide its length")
    }

    // `loadUnaligned` is intentional. The manifest is checked before this
    // access, while this also remains correct if a future ETL emits a packed
    // array at a non-natural offset.
    return file.withUnsafeBytes { raw in
        (0..<info.count).map { i in
            raw.loadUnaligned(fromByteOffset: info.byteOffset + i * MemoryLayout<T>.size,
                              as: T.self)
        }
    }
}

private func rawArrayData(_ info: ConnectomeManifest.ArrayInfo,
                          from files: [String: Data],
                          expectedDType: String,
                          expectedCount: Int) throws -> Data {
    guard info.dtype == expectedDType,
          info.components == 1,
          info.count == expectedCount,
          let elementSize = expectedDTypeBytes[info.dtype],
          let file = files[info.file] else {
        throw BrainEngineError.invalidData("edge array \(info.file) has an unexpected schema")
    }
    let bytes = try checkedByteCount(info.count, elementSize: elementSize)
    guard info.byteOffset >= 0,
          info.byteOffset <= file.count,
          bytes <= file.count - info.byteOffset else {
        throw BrainEngineError.invalidData("edge array runs past its file")
    }
    return file.subdata(in: info.byteOffset..<(info.byteOffset + bytes))
}

/// Validates the model identity before any large graph binary is opened. This
/// is intentionally internal so the manifest contract can be tested without
/// allocating a Metal simulation or a full Male CNS fixture.
func validateDatasetSelection(dataset: ConnectomeManifest.DatasetMetadata?,
                              neuralMapping: ConnectomeManifest.NeuralMapping?,
                              model: BrainModel,
                              selectedDirectory: URL) throws {
    if let datasetID = dataset?.id {
        guard !datasetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrainEngineError.invalidData("dataset.id must not be empty")
        }
        guard datasetID == model.rawValue else {
            throw BrainEngineError.invalidData(
                "manifest dataset.id " + datasetID + " does not match selected model " + model.rawValue)
        }
    }
    if let displayName = dataset?.displayName {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrainEngineError.invalidData("dataset.displayName must not be empty")
        }
    }
    if model == .maleCNS {
        guard dataset?.id == model.rawValue else {
            throw BrainEngineError.invalidData(
                "Male CNS requires dataset.id malecns")
        }
    }
    guard model != .maleCNS || neuralMapping != nil else {
        throw BrainEngineError.invalidData(
            "Male CNS requires an explicit neuralMapping; legacy role/type guessing is disabled")
    }
}

func validateNeuralMapping(_ raw: ConnectomeManifest.NeuralMapping,
                           rootIDs: [UInt64], model: BrainModel) throws -> ValidatedNeuralMapping {
    let fields: [(String, [UInt64]?)] = [
        ("odorLeft", raw.odorLeft), ("odorRight", raw.odorRight),
        ("odorRelayLeft", raw.odorRelayLeft), ("odorRelayRight", raw.odorRelayRight),
        ("taste", raw.taste), ("loomingLeft", raw.loomingLeft),
        ("loomingRight", raw.loomingRight), ("touch", raw.touch),
        ("turnLeft", raw.turnLeft), ("turnRight", raw.turnRight),
        ("forward", raw.forward), ("escape", raw.escape),
        ("feeding", raw.feeding), ("grooming", raw.grooming),
        ("flightLeft", raw.flightLeft), ("flightRight", raw.flightRight),
    ]
    // A declared mapping is all-or-nothing. This prevents a partially known
    // Male CNS annotation from silently falling through to FlyWire heuristics.
    guard fields.allSatisfy({ $0.1 != nil }) else {
        let missing = fields.filter { $0.1 == nil }.map(\.0).joined(separator: ", ")
        throw BrainEngineError.invalidData(model.displayName + " neuralMapping is missing: " + missing)
    }
    guard fields.allSatisfy({ !($0.1 ?? []).isEmpty }) else {
        let empty = fields.filter { ($0.1 ?? []).isEmpty }.map(\.0).joined(separator: ", ")
        throw BrainEngineError.invalidData(model.displayName + " neuralMapping is empty: " + empty)
    }

    var indexByRootID: [UInt64: Int] = [:]
    indexByRootID.reserveCapacity(rootIDs.count)
    for (index, rootID) in rootIDs.enumerated() {
        guard indexByRootID.updateValue(index, forKey: rootID) == nil else {
            throw BrainEngineError.invalidData("rootId contains duplicate neuron ID " + String(rootID))
        }
    }
    var used: [Int: String] = [:]
    func resolve(_ name: String, _ IDs: [UInt64]) throws -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(IDs.count)
        var local = Set<Int>()
        for rootID in IDs {
            guard let index = indexByRootID[rootID] else {
                throw BrainEngineError.invalidData(
                    model.displayName + " neuralMapping " + name +
                    " references unknown root ID " + String(rootID))
            }
            guard local.insert(index).inserted else {
                throw BrainEngineError.invalidData(
                    model.displayName + " neuralMapping " + name +
                    " contains duplicate root ID " + String(rootID))
            }
            if let previous = used[index] {
                throw BrainEngineError.invalidData(
                    model.displayName + " neuralMapping overlaps " + previous + " and " + name +
                    " at root ID " + String(rootID))
            }
            used[index] = name
            indices.append(index)
        }
        return indices
    }
    let values = try fields.map { (name, optionalIDs) in
        guard let IDs = optionalIDs else {
            throw BrainEngineError.invalidData(model.displayName + " neuralMapping is missing: " + name)
        }
        return (name, try resolve(name, IDs))
    }
    func value(_ name: String) -> [Int] {
        values.first(where: { $0.0 == name })?.1 ?? []
    }
    return ValidatedNeuralMapping(
        odorLeft: value("odorLeft"), odorRight: value("odorRight"),
        odorRelayLeft: value("odorRelayLeft"), odorRelayRight: value("odorRelayRight"),
        taste: value("taste"), loomingLeft: value("loomingLeft"),
        loomingRight: value("loomingRight"), touch: value("touch"),
        turnLeft: value("turnLeft"), turnRight: value("turnRight"),
        forward: value("forward"), escape: value("escape"),
        feeding: value("feeding"), grooming: value("grooming"),
        flightLeft: value("flightLeft"), flightRight: value("flightRight"))
}

/// Loads and validates the real graph. Every structural and digest check is
/// performed before the returned edge bytes are exposed to Metal.
func loadConnectome(dataDirectory: URL) throws -> LoadedConnectome {
    try loadConnectome(dataDirectory: dataDirectory, model: .flywireV783)
}

func loadConnectome(dataDirectory: URL, model: BrainModel) throws -> LoadedConnectome {
    let nestedDirectory = model.dataSubdirectory.isEmpty
        ? dataDirectory
        : dataDirectory.appendingPathComponent(model.dataSubdirectory, isDirectory: true)
    // Accept a direct model directory as well as a shared root. The engine's
    // default locator passes the shared root, while fixture tests often pass a
    // model directory directly. Male CNS still requires its explicit mapping,
    // so a FlyWire root cannot be mistaken for a Male CNS graph.
    let selectedDirectory: URL
    if FileManager.default.fileExists(atPath: nestedDirectory.appendingPathComponent("connectome.json").path) {
        selectedDirectory = nestedDirectory
    } else if FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connectome.json").path) {
        selectedDirectory = dataDirectory
    } else {
        selectedDirectory = nestedDirectory
    }
    let manifestURL = selectedDirectory.appendingPathComponent("connectome.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw BrainEngineError.missingData(manifestURL)
    }
    let manifestData: Data
    do {
        manifestData = try Data(contentsOf: manifestURL)
    } catch {
        throw BrainEngineError.invalidData("could not read connectome.json: \(error)")
    }

    let manifest: ConnectomeManifest
    do {
        manifest = try JSONDecoder().decode(ConnectomeManifest.self, from: manifestData)
    } catch {
        throw BrainEngineError.invalidData("connectome.json does not match its schema: \(error)")
    }
    guard manifest.format == "desktopfly-connectome-1" else {
        throw BrainEngineError.invalidData("unsupported manifest format \(manifest.format)")
    }
    guard manifest.byteOrder == "little" else {
        throw BrainEngineError.invalidData("only little-endian data is supported")
    }
    try validateDatasetSelection(dataset: manifest.dataset,
                                 neuralMapping: manifest.neuralMapping,
                                 model: model,
                                 selectedDirectory: selectedDirectory)
    guard manifest.neuronCount > 0, manifest.edgeCount > 0 else {
        throw BrainEngineError.invalidData("neuron and edge counts must be positive")
    }
    guard manifest.neuronCount <= Int(UInt32.max),
          manifest.edgeCount <= Int(UInt32.max) else {
        throw BrainEngineError.invalidData("neuron or edge count exceeds the UInt32 graph schema")
    }

    var files: [String: Data] = [:]
    for (name, info) in manifest.files {
        guard name.isSafeRelativeFileName else {
            throw BrainEngineError.invalidData("unsafe data file name \(name)")
        }
        let url = selectedDirectory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BrainEngineError.missingData(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BrainEngineError.invalidData("could not read \(name): \(error)")
        }
        guard data.count == info.bytes else {
            throw BrainEngineError.invalidData(
                "\(name) has \(data.count) bytes, manifest says \(info.bytes)")
        }
        guard hexDigest(data).caseInsensitiveCompare(info.sha256) == .orderedSame else {
            throw BrainEngineError.invalidData("SHA-256 mismatch for \(name)")
        }
        files[name] = data
    }
    guard !files.isEmpty else {
        throw BrainEngineError.invalidData("manifest contains no binary files")
    }

    let n = manifest.neuronCount
    let e = manifest.edgeCount
    let (positionCount, positionOverflow) = n.multipliedReportingOverflow(by: 3)
    let (rowCount, rowOverflow) = n.addingReportingOverflow(1)
    guard !positionOverflow, !rowOverflow else {
        throw BrainEngineError.invalidData("neuron count overflows an array shape")
    }
    func info(_ name: String) throws -> ConnectomeManifest.ArrayInfo {
        guard let value = manifest.arrays[name] else {
            throw BrainEngineError.invalidData("manifest has no array \(name)")
        }
        guard value.file.isSafeRelativeFileName else {
            throw BrainEngineError.invalidData("array \(name) has unsafe file name")
        }
        return value
    }

    let positions = try readArray(try info("pos"), from: files, expectedDType: "float32",
                                  expectedCount: positionCount, expectedComponents: 3, as: Float.self)
    // Coordinates are part of the data contract even though the first desktop
    // renderer does not need them. Reject non-finite values before the graph is
    // handed to Metal, so a corrupt artifact cannot poison a later visualizer.
    guard positions.allSatisfy({ $0.isFinite }) else {
        throw BrainEngineError.invalidData("pos contains a non-finite coordinate")
    }
    let superClass = try readArray(try info("superClass"), from: files,
                                   expectedDType: "uint8", expectedCount: n, as: UInt8.self)
    let side = try readArray(try info("side"), from: files,
                            expectedDType: "uint8", expectedCount: n, as: UInt8.self)
    let nt = try readArray(try info("nt"), from: files,
                           expectedDType: "uint8", expectedCount: n, as: UInt8.self)
    let role = try readArray(try info("role"), from: files,
                             expectedDType: "uint8", expectedCount: n, as: UInt8.self)
    let cellType = try readArray(try info("cellType"), from: files,
                                 expectedDType: "uint16", expectedCount: n, as: UInt16.self)
    let rootId = try readArray(try info("rootId"), from: files,
                               expectedDType: "uint64", expectedCount: n, as: UInt64.self)
    let rowStart = try readArray(try info("rowStart"), from: files,
                                 expectedDType: "uint32", expectedCount: rowCount, as: UInt32.self)
    let colIdxData = try rawArrayData(try info("colIdx"), from: files,
                                      expectedDType: "uint32", expectedCount: e)
    let weightData = try rawArrayData(try info("weight"), from: files,
                                      expectedDType: "int16", expectedCount: e)

    guard !manifest.stringTables.superClasses.isEmpty,
          !manifest.stringTables.sides.isEmpty,
          !manifest.stringTables.nts.isEmpty,
          !manifest.stringTables.roles.isEmpty,
          !manifest.stringTables.cellTypes.isEmpty else {
        throw BrainEngineError.invalidData("string tables must not be empty")
    }
    guard rowStart.first == 0,
          rowStart.last == UInt32(e) else {
        throw BrainEngineError.invalidData("rowStart does not span exactly edgeCount edges")
    }
    for i in 0..<n where rowStart[i] > rowStart[i + 1] {
        throw BrainEngineError.invalidData("rowStart is not monotonic at row \(i)")
    }
    guard superClass.allSatisfy({ Int($0) < manifest.stringTables.superClasses.count }),
          side.allSatisfy({ Int($0) < manifest.stringTables.sides.count }),
          nt.allSatisfy({ Int($0) < manifest.stringTables.nts.count }),
          role.allSatisfy({ Int($0) < manifest.stringTables.roles.count }),
          cellType.allSatisfy({ Int($0) < manifest.stringTables.cellTypes.count }) else {
        throw BrainEngineError.invalidData("per-neuron table contains an out-of-range id")
    }

    var maxColumn: UInt32 = 0
    var zeroWeightCount = 0
    colIdxData.withUnsafeBytes { colRaw in
        weightData.withUnsafeBytes { weightRaw in
            for i in 0..<e {
                let col = colRaw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                let weight = weightRaw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                maxColumn = max(maxColumn, col)
                if weight == 0 { zeroWeightCount += 1 }
            }
        }
    }
    guard maxColumn < UInt32(n) else {
        throw BrainEngineError.invalidData("colIdx contains neuron \(maxColumn), outside 0..<\(n)")
    }
    guard zeroWeightCount == 0 else {
        throw BrainEngineError.invalidData("\(zeroWeightCount) edges have a zero weight")
    }

    // The role counts are a second independent check on the ETL's role table.
    var observedRoleCounts = [String: Int](minimumCapacity: manifest.stringTables.roles.count)
    for id in role {
        let name = manifest.stringTables.roles[Int(id)]
        observedRoleCounts[name, default: 0] += 1
    }
    for (name, expected) in manifest.roleCounts {
        guard observedRoleCounts[name] == expected else {
            throw BrainEngineError.invalidData(
                "role \(name) has \(observedRoleCounts[name] ?? 0) neurons, manifest says \(expected)")
        }
    }

    let validatedMapping = try manifest.neuralMapping.map {
        try validateNeuralMapping($0, rootIDs: rootId, model: model)
    }
    let datasetID = manifest.dataset?.id ?? model.rawValue
    let datasetName = manifest.dataset?.displayName ?? model.displayName

    return LoadedConnectome(
        neuronCount: n,
        edgeCount: e,
        superClass: superClass,
        side: side,
        nt: nt,
        role: role,
        cellType: cellType,
        rootId: rootId,
        rowStart: rowStart,
        colIdxData: colIdxData,
        weightData: weightData,
        superClassNames: manifest.stringTables.superClasses,
        sideNames: manifest.stringTables.sides,
        ntNames: manifest.stringTables.nts,
        roleNames: manifest.stringTables.roles,
        cellTypeNames: manifest.stringTables.cellTypes,
        modulatoryNts: Set(manifest.modulatoryNts),
        modelID: datasetID,
        modelName: datasetName,
        datasetVersion: manifest.dataset?.version,
        datasetSource: manifest.dataset?.source,
        neuralMapping: validatedMapping)
}
