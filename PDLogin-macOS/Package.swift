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
        .package(name: "CommonDependencies", path: "../CommonDependencies"),
        
        // exact version is defined by CommonDependencies
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", .suitable),
        .package(name: "PDUIComponents", path: "../PDUIComponents"),
    ],
    targets: [
        .target(
            name: "PDLogin-macOS",
            dependencies: [
                .product(name: "ProtonCoreLoginUI", package: "protoncore_ios"),
            ],
            path: "PDLogin-macOS"
        ),
        .testTarget(
            name: "PDLogin-macOSTests",
            dependencies: [
                .target(name: "PDLogin-macOS"),
                .product(name: "PDUIComponents", package: "PDUIComponents"),
            ],
            path: "PDLogin-macOSTests"
        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
