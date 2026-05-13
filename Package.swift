// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanFi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FanFiCore", targets: ["FanFiCore"]),
        .executable(name: "fanfi", targets: ["fanfi"]),
        .executable(name: "FanFiApp", targets: ["FanFiApp"]),
        .executable(name: "FanFiHelper", targets: ["FanFiHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "FanFiCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "fanfi",
            dependencies: [
                "FanFiCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "FanFiApp",
            dependencies: ["FanFiCore"]
        ),
        .executableTarget(
            name: "FanFiHelper",
            dependencies: ["FanFiCore"]
        ),
    ]
)
