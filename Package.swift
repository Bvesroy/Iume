// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Iume",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Iume", targets: ["Iume"]),
        .library(name: "IumeCore", targets: ["IumeCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "IumeCore",
            dependencies: [],
            path: "Sources/IumeCore"
        ),
        .executableTarget(
            name: "Iume",
            dependencies: ["IumeCore"],
            path: "Sources/Iume"
        ),
        .executableTarget(
            name: "IumeLiveTest",
            dependencies: ["IumeCore"],
            path: "Sources/IumeLiveTest"
        ),
        .testTarget(
            name: "IumeCoreTests",
            dependencies: ["IumeCore"],
            path: "Tests/IumeCoreTests"
        )
    ]
)
