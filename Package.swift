// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OhMyOpenClaw",
    platforms: [.macOS(.v27)],
    products: [.library(name: "OhMyOpenClawCore", targets: ["OhMyOpenClawCore"])],
    targets: [
        // Verbatim TweetNaCl 20140427 (public domain) plus randombytes.c; only Core imports it.
        .target(name: "CTweetNaCl", cSettings: [.disableWarning("shorten-64-to-32")]),
        .target(name: "OhMyOpenClawCore", dependencies: ["CTweetNaCl"]),
        // The app target compiles App/ directly; this target exposes the same files to swift test.
        .target(name: "OhMyOpenClawState", dependencies: ["OhMyOpenClawCore"], path: "App",
                exclude: ["AppEnvironment.swift", "AppIcon.icon", "OhMyOpenClawApp.swift", "Platform", "PrivacyInfo.xcprivacy", "Views"],
                sources: ["AppModel.swift", "CredentialStore.swift", "GatewayProfiles.swift"]),
        // Pure Mac logic; the app target compiles the same files directly.
        .target(name: "OhMyOpenClawPlatform", dependencies: ["OhMyOpenClawCore"], path: "App/Platform"),
        .testTarget(name: "OhMyOpenClawCoreTests", dependencies: ["OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawStateTests", dependencies: ["OhMyOpenClawState", "OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawPlatformTests", dependencies: ["OhMyOpenClawPlatform", "OhMyOpenClawCore"]),
    ]
)
