// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveKoCaption",
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "LiveKoCaption", targets: ["LiveKoCaption"]),
        .executable(name: "CaptionCoreChecks", targets: ["CaptionCoreChecks"]),
        .executable(name: "TranslationSchedulingChecks", targets: ["TranslationSchedulingChecks"]),
        .executable(name: "LocalPipelineCheck", targets: ["LocalPipelineCheck"])
    ],
    targets: [
        .target(name: "CaptionCore"),
        .executableTarget(name: "LiveKoCaption", dependencies: ["CaptionCore"]),
        .executableTarget(name: "CaptionCoreChecks", dependencies: ["CaptionCore"], path: "Tests/CaptionCoreChecks"),
        .executableTarget(name: "TranslationSchedulingChecks", dependencies: ["CaptionCore"], path: "Tests/TranslationSchedulingChecks"),
        .executableTarget(name: "LocalPipelineCheck", dependencies: ["CaptionCore"], path: "Tests/LocalPipelineCheck")
    ]
)
