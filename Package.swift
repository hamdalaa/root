// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Parabolic",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Parabolic",
            path: "Sources/Parabolic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ParabolicHost",
            path: "Sources/ParabolicHost",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParabolicTests",
            dependencies: ["Parabolic"],
            path: "Tests/ParabolicTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
