// swift-tools-version:5.7

import PackageDescription

let package = Package(
	name: "DriveStressTests",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DriveStressTestsLib",
                 targets: ["DriveStressTestsLib"]),
        .executable(name: "drive-stress-tests",
                    targets: ["DriveStressTestsCLI"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DriveStressTestsCLI",
            dependencies: ["DriveStressTestsLib"],
            path: "DriveStressTestsCLI"
        ),
        .target(
            name: "DriveStressTestsLib",
            path: "DriveStressTestsLib"
        )
    ]
 )
