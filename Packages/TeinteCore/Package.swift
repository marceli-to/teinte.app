// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TeinteCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TeinteCore", targets: ["TeinteCore"]),
    ],
    targets: [
        .target(name: "TeinteCore", resources: [.process("Resources")]),
        .testTarget(
            name: "TeinteCoreTests",
            dependencies: ["TeinteCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
