// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YTMusicBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YTMusicBar", targets: ["YTMusicBar"])
    ],
    targets: [
        .target(name: "YTMusicCore"),
        .executableTarget(name: "YTMusicBar", dependencies: ["YTMusicCore"]),
        .executableTarget(
            name: "YTMusicCoreChecks",
            dependencies: ["YTMusicCore"],
            path: "Tests/YTMusicCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
