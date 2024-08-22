// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
 
let package = Package(
    name: "PDFileProvider",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PDFileProvider", targets: ["PDFileProvider"]),
    ],
    dependencies: [
        .package(name: "CommonDependencies", path: "../CommonDependencies"),
        .package(name: "PDCore", path: "../PDCore"),
        .package(name: "PDUploadVerifier", path: "../PDUploadVerifier"),
        
        // exact version is defined by CommonDependencies>ProtonCore
        .package(url: "https://github.com/AliSoftware/OHHTTPStubs", .suitable),
    ],
    targets: [
        .target(
            name: "PDFileProvider",
            dependencies: [
                .product(name: "PDCore", package: "PDCore"),
            ],
            path: "PDFileProvider"
        ),
        .testTarget(
            name: "PDFileProviderTests",
            dependencies: [
                .target(name: "PDFileProvider", condition: .when(platforms: [.iOS])),
                .product(name: "PDUploadVerifier", package: "PDUploadVerifier"),
                
                .product(name: "ProtonCoreTestingToolkit", package: "CommonDependencies"),
            ],
            path: "PDFileProviderTests"
        ),
        .testTarget(
            name: "PDFileProviderMacTests",
            dependencies: [
                .target(name: "PDFileProvider", condition: .when(platforms: [.macOS])),
                .product(name: "PDUploadVerifier", package: "PDUploadVerifier"),
                
                .product(name: "ProtonCoreTestingToolkit", package: "CommonDependencies"),
                .product(name: "OHHTTPStubs", package: "OHHTTPStubs"),
            ],
            path: "PDFileProviderMacTests"
        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
