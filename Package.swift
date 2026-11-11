// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Biblijeu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Biblijeu",
            path: "Sources/Biblijeu",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Run with Tests/run-unit.sh (or `swift test`).
        .testTarget(
            name: "BiblijeuTests",
            dependencies: ["Biblijeu"],
            path: "Tests/BiblijeuTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
