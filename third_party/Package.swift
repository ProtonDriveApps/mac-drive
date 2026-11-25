// swift-tools-version: 5.9
import PackageDescription

// External dependencies only. Local Drive modules own native BUILD.bazel files.
// Requirements come from local package definitions and the app project, not
// Xcode's resolution. Package.resolved records a fresh resolution of these inputs.
let package = Package(
    name: "DriveBazelDependencies",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/AliSoftware/OHHTTPStubs", exact: "9.1.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/ProtonDriveApps/sdk-swift.git", branch: "0.32.1-rust"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.21"),
        .package(url: "https://github.com/ProtonMail/TrustKit.git", exact: "1.0.3"),
        .package(url: "https://github.com/ashleymills/Reachability.swift", exact: "5.2.4"),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "38.0.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.35.0"),
        .package(url: "https://github.com/Unleash/unleash-ios-sdk.git", exact: "2.5.2"),
    ]
)
