import Foundation

enum DataLocator {
    static func directory() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["NEUROFLY_DATA_DIR"] {
            let directory = URL(fileURLWithPath: explicit, isDirectory: true)
            guard fm.fileExists(atPath: directory.appendingPathComponent("connectome.json").path) else {
                throw NSError(domain: "NeuroFly", code: 2, userInfo: [NSLocalizedDescriptionKey: "NEUROFLY_DATA_DIR에 연결 데이터가 없습니다: \(explicit)"])
            }
            return directory
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("data"),
                  fm.fileExists(atPath: bundled.appendingPathComponent("connectome.json").path) else {
                throw NSError(domain: "NeuroFly", code: 3, userInfo: [NSLocalizedDescriptionKey: "앱에 연결 데이터가 포함되지 않았습니다. 앱 패키지를 다시 빌드해 주세요."])
            }
            return bundled
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("data"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(project.appendingPathComponent("data"))
        guard let found = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("connectome.json").path) }) else {
            throw NSError(domain: "NeuroFly", code: 1, userInfo: [NSLocalizedDescriptionKey: "FlyWire 데이터를 찾지 못했습니다. data 폴더를 포함해 앱을 다시 빌드해 주세요."])
        }
        return found
    }
}
