// swift-tools-version:5.9
import PackageDescription
import Foundation

// Absolute path to the vendored sherpa-onnx static library, resolved relative
// to this manifest so the package builds wherever it is cloned.
let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLibDir = "\(pkgDir)/third_party/sherpa/lib"

let package = Package(
    name: "ode",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT v3 ASR (CoreML, Apple Neural Engine) for the
        // alternative meeting-transcription engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "CSherpa",
            path: "Sources/CSherpa",
            sources: ["shim.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "ODEKit",
            dependencies: [
                "CSherpa",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/ODEKit",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(sherpaLibDir)",
                    "-lsherpa-onnx-c-api",
                    "-lsherpa-onnx-core",
                    "-lsherpa-onnx-fst",
                    "-lsherpa-onnx-fstfar",
                    "-lsherpa-onnx-kaldifst-core",
                    "-lkaldi-decoder-core",
                    "-lkaldi-native-fbank-core",
                    "-lkissfft-float",
                    "-lssentencepiece_core",
                    "-lpiper_phonemize",
                    "-lespeak-ng",
                    "-lucd",
                    "-lonnxruntime",
                    "-lc++"
                ]),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "ode",
            dependencies: ["ODEKit"],
            path: "Sources/ode"
        ),
        .executableTarget(
            name: "ODEApp",
            dependencies: ["ODEKit"],
            path: "Sources/ODEApp"
        )
    ]
)
