// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PiVoiceMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PiVoiceMac", targets: ["PiVoiceMac"]),
        .library(name: "PiVoiceMacCore", targets: ["PiVoiceMacCore"]),
        .library(name: "PiVoiceMacSecurity", targets: ["PiVoiceMacSecurity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.03"),
    ],
    targets: [
        .target(name: "PiVoiceMacCore"),
        .target(name: "PiVoiceMacSecurity", dependencies: ["PiVoiceMacCore"]),
        .target(
            name: "PiVoiceMacAudioMeter",
            dependencies: ["PiVoiceMacCore", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")]
        ),
        .executableTarget(
            name: "PiVoiceMac",
            dependencies: ["PiVoiceMacCore", "PiVoiceMacSecurity", "PiVoiceMacAudioMeter", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(name: "PiVoiceMacCoreChecks", dependencies: ["PiVoiceMacCore", "PiVoiceMacSecurity"]),
        .executableTarget(name: "PiVoiceMacMeterChecks", dependencies: ["PiVoiceMacAudioMeter"]),
    ]
)
