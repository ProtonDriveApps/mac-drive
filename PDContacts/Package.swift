// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDContacts",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(name: "PDContacts", targets: ["PDContacts"]),
    ],
    dependencies: [

        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "38.0.0"),
        .package(url: "https://github.com/ProtonMail/apple-fusion.git", exact: "2.1.6"),
    ],
    targets: [
        .target(
            name: "PDContacts",
            dependencies: [
                .product(name: "ProtonCoreNetworking", package: "protoncore_ios"),
                .product(name: "ProtonCoreServices", package: "protoncore_ios")
            ],
            path: "Sources"
        ),
    ]
)
