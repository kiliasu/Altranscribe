// swift-tools-version: 6.2
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "Altranscribe",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Altranscribe", targets: ["Altranscribe"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxMacOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip",
            checksum: "93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5"
        ),
        .binaryTarget(
            name: "OnnxruntimeMacOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.1/onnxruntime-macos-static-xcframework-1.28.1.xcframework.zip",
            checksum: "38c9a1e8bcf2497ff5eb721195743e4b4367ade3cd1eb9869c0cfd1bd367c36b"
        ),
        .target(
            name: "WhisperBridge",
            cxxSettings: [.unsafeFlags(["-I\(root)/.build/whisper-src/include", "-I\(root)/.build/whisper-src/ggml/include"])],
            linkerSettings: [
                .unsafeFlags(["\(root)/.build/native/libAltranscribeWhisper.a"]),
                .linkedFramework("Accelerate"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("Foundation"), .linkedLibrary("c++")
            ]
        ),
        .target(name: "AltranscribeCore", dependencies: ["WhisperBridge", "SherpaOnnxMacOS", "OnnxruntimeMacOS",
                                                       .product(name: "FluidAudio", package: "FluidAudio")],
                resources: [.process("Resources")],
                linkerSettings: [.linkedFramework("CoreML")]),
        .executableTarget(name: "Altranscribe", dependencies: ["AltranscribeCore"]),
        .testTarget(name: "AltranscribeCoreTests", dependencies: ["AltranscribeCore"]),
        .testTarget(name: "AltranscribeAppTests", dependencies: ["Altranscribe"])
    ],
    cxxLanguageStandard: .cxx17
)
