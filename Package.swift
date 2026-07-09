// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Parfait",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "Parfait",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Parfait",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParfaitTests",
            dependencies: ["Parfait"],
            path: "Tests/ParfaitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
