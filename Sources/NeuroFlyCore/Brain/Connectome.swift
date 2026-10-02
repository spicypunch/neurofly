import CryptoKit
import Foundation

/// Errors raised while loading the shipped FlyWire-derived graph.
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

    let format: String
    let neuronCount: Int
    let edgeCount: Int
    let byteOrder: String
    let files: [String: FileInfo]
    let arrays: [String: ArrayInfo]
    let stringTables: StringTables
    let roleCounts: [String: Int]
    let modulatoryNts: [String]
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

/// Loads and validates the real graph. Every structural and digest check is
/// performed before the returned edge bytes are exposed to Metal.
func loadConnectome(dataDirectory: URL) throws -> LoadedConnectome {
    let manifestURL = dataDirectory.appendingPathComponent("connectome.json", isDirectory: false)
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
        let url = dataDirectory.appendingPathComponent(name, isDirectory: false)
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
        modulatoryNts: Set(manifest.modulatoryNts))
}
