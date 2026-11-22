// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Boss",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BossCore", targets: ["BossCore"]),
        .executable(name: "Boss", targets: ["BossApp"]),
    ],
    targets: [
        .target(name: "BossCore", path: "Sources/BossCore"),
        .executableTarget(name: "BossApp", dependencies: ["BossCore"], path: "Sources/BossApp"),
        .testTarget(name: "BossCoreTests", dependencies: ["BossCore"], path: "Tests/BossCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
