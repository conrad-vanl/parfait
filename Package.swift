// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Parfait",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Parfait",
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
