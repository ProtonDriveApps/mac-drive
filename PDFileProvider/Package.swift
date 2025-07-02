// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDFileProvider",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PDFileProvider", targets: ["PDFileProvider"]),
    ],
    dependencies: [
        .package(name: "PDClient", path: "../PDClient"),
        .package(name: "PDCore", path: "../PDCore"),
        .package(name: "PDLocalization", path: "../PDLocalization"),
        .package(name: "PDUploadVerifier", path: "../PDUploadVerifier"),
        .package(name: "PMEventsManager", path: "../PMEventsManager"),
        // exact version is defined by PDClient>ProtonCore
        .package(url: "https://github.com/AliSoftware/OHHTTPStubs", .suitable),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "32.7.1"),
    ],
    targets: [
        .target(
            name: "PDFileProvider",
            dependencies: [
                .product(name: "PDCore", package: "PDCore"),
                .product(name: "PDLocalization", package: "PDLocalization"),
                .product(name: "PMEventsManager", package: "PMEventsManager"),
            ],
            path: "PDFileProvider"
        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
