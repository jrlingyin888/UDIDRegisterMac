// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UDIDRegisterMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UDIDRegisterKit"),
        .testTarget(name: "UDIDRegisterKitTests", dependencies: ["UDIDRegisterKit"]),
    ]
)
