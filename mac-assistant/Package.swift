// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScreenLinkMacAssistant",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "screenlink-mac-probe", targets: ["ScreenLinkMacProbe"])],
    targets: [
        .target(name: "ScreenLinkMacCore"),
        .executableTarget(name: "ScreenLinkMacProbe", dependencies: ["ScreenLinkMacCore"]),
        .testTarget(name: "ScreenLinkMacCoreTests", dependencies: ["ScreenLinkMacCore"])
    ]
)
