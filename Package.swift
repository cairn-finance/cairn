// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CairnCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
    ],
    targets: [
        .target(
            name: "CairnCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CairnCoreTests",
            dependencies: ["CairnCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
