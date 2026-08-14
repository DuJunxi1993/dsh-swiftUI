// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHShell",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DSHShell", targets: ["DSHShell"]),
        .library(name: "DSHShellCore", targets: ["DSHShellCore"])
    ],
    targets: [
        .target(
            name: "DSHShellCore",
            path: "Sources/DSHShellCore"
        ),
        .executableTarget(
            name: "DSHShell",
            dependencies: ["DSHShellCore"],
            path: "Sources/DSHShell"
        ),
        .testTarget(
            name: "DSHShellCoreTests",
            dependencies: ["DSHShellCore"],
            path: "Tests/DSHShellCoreTests"
        )
    ]
)
