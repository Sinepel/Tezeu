// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tezeu",
    platforms: [.macOS(.v14)],
    targets: [
        // whisper.cpp b5454 (v1.9.5), licence MIT. Version compilée officielle :
        // https://github.com/ggml-org/whisper.cpp/releases/tag/b5454
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        // Code partagé entre l'app et le programme de vérification.
        .target(name: "TezeuCore", dependencies: ["whisper"], path: "Sources/TezeuCore"),
        .executableTarget(
            name: "Tezeu",
            dependencies: ["TezeuCore"],
            path: "Sources/Tezeu",
            linkerSettings: [
                // L'app cherche whisper.framework dans Tezeu.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Vérifications lancées avec `swift run SelfCheck` (remplace `swift test`, absent sans Xcode).
        .executableTarget(name: "SelfCheck", dependencies: ["TezeuCore"], path: "Sources/SelfCheck"),
    ]
)
