// swift-tools-version: 6.0
import PackageDescription

// App layer shared by the iPhone app (Habla) and the Mac app (Habla Studio):
// design system, Books-style paged reader, narration player, stores bound to HablaCore.
let package = Package(
    name: "HablaUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HablaUI", targets: ["HablaUI"]),
        .executable(name: "habla-snapshots", targets: ["habla-snapshots"]),
    ],
    dependencies: [.package(path: "../HablaCore")],
    targets: [
        .target(name: "HablaUI", dependencies: [.product(name: "HablaCore", package: "HablaCore")]),
        // Renders screens with real books to PNG on the Mac (no simulator needed).
        .executableTarget(name: "habla-snapshots", dependencies: ["HablaUI", .product(name: "HablaCore", package: "HablaCore")]),
        .testTarget(name: "HablaUITests", dependencies: ["HablaUI", .product(name: "HablaCore", package: "HablaCore")]),
    ],
    swiftLanguageModes: [.v5]
)
