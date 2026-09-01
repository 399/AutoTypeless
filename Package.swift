// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AutoTypeless",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AutoTypelessCore", targets: ["AutoTypelessCore"]),
        .executable(name: "autotypeless", targets: ["AutoTypelessCLI"]),
        .executable(name: "AutoTypelessMenuBar", targets: ["AutoTypelessMenuBar"])
    ],
    targets: [
        .target(name: "AutoTypelessCore"),
        .executableTarget(
            name: "AutoTypelessCLI",
            dependencies: ["AutoTypelessCore"]
        ),
        .executableTarget(
            name: "AutoTypelessMenuBar",
            dependencies: ["AutoTypelessCore"]
        ),
        .testTarget(
            name: "AutoTypelessCoreTests",
            dependencies: ["AutoTypelessCore"]
        )
    ]
)
