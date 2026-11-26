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
                sources: ["AppModel.swift", "CredentialStore.swift", "GatewayProfiles.swift"]),
        .testTarget(name: "OhMyOpenClawCoreTests", dependencies: ["OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawStateTests", dependencies: ["OhMyOpenClawState", "OhMyOpenClawCore"]),
    ]
)
