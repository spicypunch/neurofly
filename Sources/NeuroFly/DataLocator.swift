import Foundation
import NeuroFlyCore

/// Selecting a missing model fails rather than silently using another graph.
enum DataLocator {
    static func directory(model: BrainModel = .flywireV783) throws -> URL {
        let fm = FileManager.default
        for root in roots() {
            let nested = model.dataSubdirectory.isEmpty ? root :
                root.appendingPathComponent(model.dataSubdirectory, isDirectory: true)
            for candidate in [nested, root] {
                let manifest = candidate.appendingPathComponent("connectome.json")
                guard fm.fileExists(atPath: manifest.path), matches(model, manifest: manifest) else { continue }
                return candidate
            }
        }
        throw NSError(domain: "NeuroFly", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "\(model.displayName) 연결 데이터를 찾지 못했습니다. 해당 데이터를 준비한 뒤 앱을 다시 빌드해 주세요."])
    }

    static var availableModels: [BrainModel] {
        BrainModel.allCases.filter { (try? directory(model: $0)) != nil }
    }

    static var preferredModel: BrainModel {
        availableModels.contains(.maleCNS) ? .maleCNS : .flywireV783
    }

    /// Old diagnostic commands retain FlyWire unless a model is specified.
    static func commandLineModel() throws -> BrainModel {
        let args = CommandLine.arguments
        let argument: String?
        if let inline = args.first(where: { $0.hasPrefix("--model=") }) {
            argument = String(inline.dropFirst("--model=".count))
        } else if let index = args.firstIndex(of: "--model") {
            guard index + 1 < args.count else {
                throw BrainEngineError.invalidArgument("--model requires flywire-v783 or malecns")
            }
            argument = args[index + 1]
        } else {
            argument = ProcessInfo.processInfo.environment["NEUROFLY_MODEL"]
        }
        guard let argument else { return .flywireV783 }
        guard let model = BrainModel(rawValue: argument) else {
            throw BrainEngineError.invalidArgument("Unknown brain model: \(argument)")
        }
        return model
    }

    private static func roots() -> [URL] {
        if let explicit = ProcessInfo.processInfo.environment["NEUROFLY_DATA_DIR"] {
            return [URL(fileURLWithPath: explicit, isDirectory: true)]
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.resourceURL.map { [$0.appendingPathComponent("data", isDirectory: true)] } ?? []
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data"),
                project.appendingPathComponent("data")]
    }

    private static func matches(_ model: BrainModel, manifest: URL) -> Bool {
        guard let data = try? Data(contentsOf: manifest),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let dataset = value["dataset"] as? [String: Any]
        // Original pinned FlyWire manifests predate explicit dataset metadata.
        let id = dataset?["id"] as? String ?? BrainModel.flywireV783.rawValue
        guard id == model.rawValue, let files = value["files"] as? [String: [String: Any]],
              !files.isEmpty else { return false }
        let root = manifest.deletingLastPathComponent()
        // This is a quick availability check, not integrity validation. The
        // engine verifies every SHA-256 and array before a model is activated.
        return files.allSatisfy { name, info in
            guard !name.isEmpty, !name.contains("/"), !name.contains(".."),
                  let expected = info["bytes"] as? Int, expected > 0,
                  let size = try? root.appendingPathComponent(name)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return size == expected
        }
    }
}
