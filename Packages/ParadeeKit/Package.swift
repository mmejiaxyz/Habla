// swift-tools-version: 6.0
import PackageDescription

// Paradee on the iPhone: the same voice Habla for Mac uses (Paradee 1.3, int8), run natively with
// ONNX Runtime instead of Python. Only the iPhone app links it; HablaCore stays dependency-free.
// Run Scripts/fetch-paradee.sh first: it downloads ONNX Runtime and the model files (hash-pinned)
// into Vendor/ and Sources/ParadeeKit/Resources/, which are gitignored.
let package = Package(
    name: "ParadeeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ParadeeKit", targets: ["ParadeeKit"]),
    ],
    dependencies: [.package(path: "../HablaCore")],
    targets: [
        // Static ONNX Runtime for the iPhone (and simulator).
        .binaryTarget(name: "ORTiOS", path: "Vendor/ORTiOS.xcframework"),
        // The macOS dylib, so the port can be tested against Python Paradee with `swift test`.
        .binaryTarget(name: "ORTmac", path: "Vendor/ORTmac.xcframework"),
        .target(
            name: "ParadeeKit",
            dependencies: [
                .product(name: "HablaCore", package: "HablaCore"),
                .target(name: "ORTiOS", condition: .when(platforms: [.iOS])),
                .target(name: "ORTmac", condition: .when(platforms: [.macOS])),
            ],
            resources: [.copy("Resources")],
            // The static ONNX Runtime uses the system's zlib and SQLite.
            linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Foundation"),
                             .linkedLibrary("z"), .linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ParadeeKitTests", dependencies: ["ParadeeKit"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
