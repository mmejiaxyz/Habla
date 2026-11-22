// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HablaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HablaCore", targets: ["HablaCore"]),
        .executable(name: "habla", targets: ["habla"]),
    ],
    targets: [
        // Zero third-party dependencies: only Apple frameworks.
        .target(name: "HablaCore"),
        .executableTarget(name: "habla", dependencies: ["HablaCore"]),
        .testTarget(name: "HablaCoreTests", dependencies: ["HablaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
