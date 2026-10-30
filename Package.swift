// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kumquat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kumquat", targets: ["Kumquat"]),
        .library(name: "KumquatCore", targets: ["KumquatCore"]),
    ],
    targets: [
        // Pure services: preview routing, metadata, conversion, text extraction.
        // No UI state, fully unit-testable.
        .target(name: "KumquatCore"),
        // The menu-bar app. Main-actor by default: every type here is UI glue.
        .executableTarget(
            name: "Kumquat",
            dependencies: ["KumquatCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "KumquatCoreTests", dependencies: ["KumquatCore"]),
    ]
)
