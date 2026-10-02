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
        )
    ]
)
