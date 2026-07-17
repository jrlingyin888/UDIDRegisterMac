// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UDIDRegisterMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UDIDRegisterKit"),
        .testTarget(name: "UDIDRegisterKitTests", dependencies: ["UDIDRegisterKit"]),
        .target(name: "ReSignKit", dependencies: ["UDIDRegisterKit"]),
        .testTarget(name: "ReSignKitTests", dependencies: ["ReSignKit", "UDIDRegisterKit"]),
        .executableTarget(name: "UDIDRegisterApp", dependencies: ["UDIDRegisterKit"]),
        .target(name: "ReSignAppCore", dependencies: ["UDIDRegisterKit", "ReSignKit"]),
        .testTarget(name: "ReSignAppCoreTests", dependencies: ["ReSignAppCore", "ReSignKit", "UDIDRegisterKit"]),
        .executableTarget(name: "ReSignApp", dependencies: ["ReSignAppCore"]),
    ]
)
