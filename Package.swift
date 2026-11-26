// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OhMyOpenClaw",
    platforms: [.macOS(.v27)],
    products: [.library(name: "OhMyOpenClawCore", targets: ["OhMyOpenClawCore"])],
    targets: [
        .target(name: "OhMyOpenClawCore"),
        // The app target compiles App/ directly; this target exposes the same files to swift test.
        .target(name: "OhMyOpenClawState", dependencies: ["OhMyOpenClawCore"], path: "App",
                exclude: ["Platform"],
                sources: ["AppModel.swift", "CredentialStore.swift", "GatewayProfiles.swift"]),
        // Pure Mac logic; the app target compiles the same files directly.
        .target(name: "OhMyOpenClawPlatform", dependencies: ["OhMyOpenClawCore"], path: "App/Platform"),
        .testTarget(name: "OhMyOpenClawCoreTests", dependencies: ["OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawStateTests", dependencies: ["OhMyOpenClawState", "OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawPlatformTests", dependencies: ["OhMyOpenClawPlatform", "OhMyOpenClawCore"]),
    ]
)
