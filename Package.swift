// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrainInput",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BrainCore", targets: ["BrainCore"]),
        .library(name: "BrainWhisper", targets: ["BrainWhisper"]),
        .executable(name: "BrainInputApp", targets: ["BrainInputApp"]),
        .executable(name: "brain", targets: ["brain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "762baf6733ca0f0dbeb1ce335363fc75066bd2c9"),
    ],
    targets: [
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .target(name: "BrainCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "BrainWhisper", dependencies: ["BrainCore", "whisper", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "BrainInputApp", dependencies: ["BrainCore", "BrainWhisper"]),
        .executableTarget(name: "brain", dependencies: ["BrainCore", "BrainWhisper"]),
        .testTarget(name: "BrainCoreTests", dependencies: ["BrainCore"]),
        .testTarget(name: "BrainWhisperTests", dependencies: ["BrainCore", "BrainWhisper"]),
    ],
    swiftLanguageModes: [.v5]
)
