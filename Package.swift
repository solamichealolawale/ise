// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ise",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ise", path: "Sources/Ise"),
        .testTarget(name: "IseTests", dependencies: ["Ise"], path: "Tests/IseTests")
    ]
)
