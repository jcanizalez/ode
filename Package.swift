// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ode",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-O3", "-DNDEBUG", "-Wno-everything"])
            ]
        ),
        .executableTarget(
            name: "ode",
            dependencies: ["CRNNoise"],
            path: "Sources/ode"
        )
    ]
)
