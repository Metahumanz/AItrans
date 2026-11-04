// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AITrans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AITransCore", targets: ["AITransCore"]),
        .executable(name: "AITransApp", targets: ["AITransApp"]),
    ],
    targets: [
        .target(name: "AITransCore"),
        .executableTarget(name: "AITransApp", dependencies: ["AITransCore"]),
        .testTarget(name: "AITransCoreTests", dependencies: ["AITransCore"]),
    ],
    swiftLanguageModes: [.v5]
)
