// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spoon",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpoonApp", targets: ["SpoonApp"]),
        .executable(name: "spoon", targets: ["SpoonCLI"]),
        .executable(name: "SpoonAskpass", targets: ["SpoonAskpass"]),
        .library(name: "SpoonKit", targets: ["SpoonKit"]),
    ],
    targets: [
        // Pure Swift core, no AppKit (§4.2).
        .target(name: "SpoonKit"),
        .executableTarget(name: "SpoonCLI", dependencies: ["SpoonKit"]),
        .executableTarget(name: "SpoonAskpass"),
        // ponytail: UI lives in the app target; split out SpoonUI when a second host needs it.
        .executableTarget(name: "SpoonApp", dependencies: ["SpoonKit"]),
        .testTarget(name: "SpoonKitTests", dependencies: ["SpoonKit"]),
    ]
)
