// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDLogin-macOS",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PDLogin-macOS", targets: ["PDLogin-macOS"]),
    ],
    dependencies: [

        // exact version is defined by PDClient
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "32.7.1"),
        .package(name: "PDUIComponents", path: "../PDUIComponents"),
    ],
    targets: [
        .target(
            name: "PDLogin-macOS",
            dependencies: [
                .product(name: "ProtonCoreHumanVerification", package: "protoncore_ios"),
                .product(name: "ProtonCoreLoginUI", package: "protoncore_ios"),
            ],
            path: "PDLogin-macOS",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
