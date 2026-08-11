// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Blink",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BlinkCore", targets: ["BlinkCore"]),
        .executable(name: "Blink", targets: ["Blink"]),
    ],
    targets: [
        .target(name: "BlinkCore"),
        .executableTarget(name: "Blink", dependencies: ["BlinkCore"]),
        .testTarget(name: "BlinkCoreTests", dependencies: ["BlinkCore"]),
        .testTarget(name: "BlinkTests", dependencies: ["Blink"]),
    ]
)
