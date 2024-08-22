// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
 
let package = Package(
    name: "PDClient",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PDClient", targets: ["PDClient"]),
    ],
    dependencies: [
        .package(name: "CommonDependencies", path: "../CommonDependencies"),
        
        // exact version is defined by CommonDependencies
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", .suitable),
        .package(url: "https://github.com/ProtonMail/apple-fusion.git", .suitable),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", .suitable),
        .package(url: "https://github.com/Unleash/unleash-proxy-client-swift.git", .suitable),
        .package(url: "https://github.com/ProtonMail/TrustKit.git", .suitable),
    ],
    targets: [
        .target(
            name: "PDClient",
            dependencies: [
                .product(name: "ProtonCoreUtilities", package: "protoncore_ios"),
                .product(name: "ProtonCoreNetworking", package: "protoncore_ios"),
                .product(name: "ProtonCoreServices", package: "protoncore_ios"),
                
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "UnleashProxyClientSwift", package: "unleash-proxy-client-swift"),
            ],
            path: "PDClient"
        ),
        .testTarget(
            name: "PDClientUnitTests",
            dependencies: [
                .target(name: "PDClient"),
                
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "TrustKit", package: "TrustKit"),
            ],
            path: "PDClientUnitTests"
        ),
        .testTarget(
            name: "PDClientIntegrationTests",
            dependencies: [
                .target(name: "PDClient"),
                
                .product(name: "fusion", package: "apple-fusion"),
                .product(name: "ProtonCoreTestingToolkit", package: "CommonDependencies"),
                .product(name: "ProtonCoreUtilities", package: "protoncore_ios"),
                .product(name: "ProtonCoreAuthentication", package: "protoncore_ios"),
                .product(name: "ProtonCoreQuarkCommands", package: "protoncore_ios"),
                .product(name: "ProtonCoreCryptoGoImplementation", package: "protoncore_ios"),
                
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "TrustKit", package: "TrustKit"),
            ],
            path: "PDClientIntegrationTests"
        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
