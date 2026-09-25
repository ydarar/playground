// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Goldie",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: Cursor sensors, signals, brain, handoff. No UI.
        .target(name: "GoldieCore"),
        // The floating goldfish + menu bar app.
        .executableTarget(name: "Goldie", dependencies: ["GoldieCore"]),
        // CLI: Cursor hook sink, hook installer, probe, snapshot dump.
        .executableTarget(name: "goldiectl", dependencies: ["GoldieCore"]),
        // Tests without XCTest (Command Line Tools only): `swift run goldie-selftest`.
        .executableTarget(name: "goldie-selftest", dependencies: ["GoldieCore"], path: "Tests/GoldieSelfTest"),
    ]
)
