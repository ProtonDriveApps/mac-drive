// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDFileProviderOperations",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PDFileProviderOperations",
            targets: ["PDFileProviderOperations"]),
    ],
    dependencies: [
        .package(name: "PDClient", path: "../PDClient"),
        .package(name: "PDCore", path: "../PDCore"),
        .package(name: "PDFileProvider", path: "../PDFileProvider"),
        .package(name: "PDDesktopDevKit", path: "../PDDesktopDevKit"),
        .package(name: "PDUploadVerifier", path: "../PDUploadVerifier"),

        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "32.7.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PDFileProviderOperations",
            dependencies: [
                .product(name: "PDClient", package: "PDClient"),
                .product(name: "PDCore", package: "PDCore"),
                .product(name: "PDFileProvider", package: "PDFileProvider"),
                .product(name: "PDDesktopDevKit", package: "PDDesktopDevKit"),
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
                .product(name: "ProtonCoreDataModel", package: "protoncore_ios"),
                .product(name: "ProtonCoreServices", package: "protoncore_ios"),
                .product(name: "ProtonCoreUtilities", package: "protoncore_ios"),
            ]),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
