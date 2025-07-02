// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PDCore", targets: ["PDCore"]),
    ],
    dependencies: [
        .package(name: "PDClient", path: "../PDClient"),
        .package(name: "PMEventsManager", path: "../PMEventsManager"),
        .package(name: "PDLocalization", path: "../PDLocalization"),
        .package(name: "PDUIComponents", path: "../PDUIComponents"),
        .package(name: "PDContacts", path: "../PDContacts"),

        // exact version is defined by CommonDependencies
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "32.7.1"),
        .package(url: "https://github.com/ProtonMail/apple-fusion.git", .suitable),
        .package(url: "https://github.com/ProtonMail/TrustKit.git", .suitable),
        .package(url: "https://github.com/ashleymills/Reachability.swift", .suitable),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        .target(
            name: "PDCore",
            dependencies: [
                .product(name: "PDClient", package: "PDClient"),
                .product(name: "PMEventsManager", package: "PMEventsManager"),
                .product(name: "PDLocalization", package: "PDLocalization"),

                .product(name: "ProtonCoreAuthentication", package: "protoncore_ios"),
                .product(name: "ProtonCoreAPIClient", package: "protoncore_ios"),
                .product(name: "ProtonCoreChallenge", package: "protoncore_ios", condition: .when(platforms: [.iOS])),
                .product(name: "ProtonCoreCrypto", package: "protoncore_ios"),
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
                .product(name: "ProtonCoreDataModel", package: "protoncore_ios"),
                .product(name: "ProtonCoreEnvironment", package: "protoncore_ios"),
                .product(name: "ProtonCoreFeatureFlags", package: "protoncore_ios"),
                .product(name: "ProtonCoreKeyManager", package: "protoncore_ios"),
                .product(name: "ProtonCoreKeymaker", package: "protoncore_ios"),
                .product(name: "ProtonCoreNetworking", package: "protoncore_ios"),
                .product(name: "ProtonCoreObservability", package: "protoncore_ios"),
                .product(name: "ProtonCorePayments", package: "protoncore_ios"),
                .product(name: "ProtonCorePushNotifications", package: "protoncore_ios"),
                .product(name: "ProtonCoreServices", package: "protoncore_ios"),
                .product(name: "ProtonCoreTelemetry", package: "protoncore_ios"),
                .product(name: "ProtonCoreUtilities", package: "protoncore_ios"),

                .product(name: "Reachability", package: "Reachability.swift"),
                .product(name: "TrustKit", package: "TrustKit"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "PDCore",
            resources: [
                .process("CoreData/Metadata.xcdatamodeld"),
                .process("EventsProcessor/Storage/Events/EventStorageModel.xcdatamodeld"),
                .process("EventsProcessor/Storage/Events/Events to Events v1.17.xcmappingmodel"),
                .process("Syncing/SyncModel.xcdatamodeld"),
            ],
            swiftSettings: [
                .define("RESOURCES_ARE_IMPORTED_BY_SPM"),
                .define("INCLUDES_DB_IN_BUGREPORT", .when(configuration: .debug)),
            ]

        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
