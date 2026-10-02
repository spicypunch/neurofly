// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeuroFly",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "NeuroFly", targets: ["NeuroFly"])],
    targets: [
        .target(name: "NeuroFlyCore", resources: [.copy("Resources")]),
        .executableTarget(name: "NeuroFly", dependencies: ["NeuroFlyCore"]),
        .testTarget(name: "NeuroFlyCoreTests", dependencies: ["NeuroFlyCore"])
    ],
    swiftLanguageModes: [.v5]
)
