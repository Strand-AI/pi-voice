// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiVoicePhone",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "PiVoiceCore", targets: ["PiVoiceCore"]),
        .executable(name: "PiVoiceCoreChecks", targets: ["PiVoiceCoreChecks"]),
    ],
    targets: [
        .target(name: "PiVoiceCore"),
        // The installed CommandLineTools image has no discoverable XCTest/Testing module.
        // This zero-dependency executable runs the same deterministic fake-call contract checks.
        .executableTarget(name: "PiVoiceCoreChecks", dependencies: ["PiVoiceCore"]),
    ]
)
