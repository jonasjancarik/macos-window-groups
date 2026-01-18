// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowGroups",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowGroups", targets: ["WindowGroups"])
    ],
    targets: [
        .executableTarget(name: "WindowGroups")
    ]
)
