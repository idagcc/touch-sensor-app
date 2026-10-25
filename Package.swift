// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchPlayer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TouchPlayer", targets: ["TouchPlayer"])],
    targets: [
        .target(name: "TouchPlayerCore"),
        .executableTarget(name: "TouchPlayer", dependencies: ["TouchPlayerCore"]),
        .testTarget(name: "TouchPlayerCoreTests", dependencies: ["TouchPlayerCore"])
    ]
)
