// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The Rust engine is built by `scripts/build-rust.sh` into a static library and
// linked into IumeCore. Keeping the path absolute here means the linker finds
// it regardless of the working directory SwiftPM uses.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLibDirectory = "\(packageRoot)/crates/iume_engine/target/release"

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
            name: "CIumeEngine",
            path: "Sources/CIumeEngine",
            publicHeadersPath: "include"
        ),
        .target(
            name: "IumeCore",
            dependencies: ["CIumeEngine"],
            path: "Sources/IumeCore",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDirectory, "-liume_engine"])
            ]
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
