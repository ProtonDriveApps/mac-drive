// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let package = Package(
    name: "PDFileProviderOperations",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "PDFileProviderOperations",
            targets: ["PDFileProviderOperations"]),
    ],
    dependencies: [
        .package(name: "PDClient", path: "../PDClient"),
        .package(name: "PDCore", path: "../PDCore"),
        .package(name: "PDSDKCore", path: "../PDSDKCore"),
        .package(name: "PDFileProvider", path: "../PDFileProvider"),
        .package(name: "PDUploadVerifier", path: "../PDUploadVerifier"),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "37.0.1"),
        .package(url: "https://github.com/AliSoftware/OHHTTPStubs", exact: "9.1.0"),
    ],
    targets: [
        .target(
            name: "PDFileProviderOperations",
            dependencies: [
                .product(name: "PDClient", package: "PDClient"),
                .product(name: "PDCore", package: "PDCore"),
                .product(name: "PDSDKCore", package: "PDSDKCore"),
                .product(name: "PDFileProvider", package: "PDFileProvider"),
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
                .product(name: "ProtonCoreDataModel", package: "protoncore_ios"),
                .product(name: "ProtonCoreServices", package: "protoncore_ios"),
                .product(name: "ProtonCoreUtilities", package: "protoncore_ios"),
            ]
        ),
    ]
)
