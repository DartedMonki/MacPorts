// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortsApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PortsApp",
            path: "PortsApp",
            exclude: ["Assets.xcassets", "Info.plist", "PortsApp.entitlements"]
        ),
        .testTarget(
            name: "PortsAppTests",
            dependencies: ["PortsApp"]
        )
    ]
)
