// swift-tools-version: 5.9.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PDDesktopDevKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "PDDesktopDevKit",
            targets: ["PDDesktopDevKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),

        // for tests
        .package(name: "PDClient", path: "../PDClient"),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "32.7.1"),
    ],
    targets: [
        .target(
            name: "PDDesktopDevKit",
            dependencies: [
                "ProtonDriveDDK",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]),
        .binaryTarget(
          name: "ProtonDriveDDK",
//          path: "./Libraries/ProtonDriveDDK.xcframework"

          /// Updating the DDK:
          /// 1. Update URL to point to the latest framework .zip file
          /// 2. Update the SHA256 checksum of the framework .zip file
          /// 3. Checkout the commit used to generate the latest framework version in your local DDK repo clone
          /// 4. Regenerate the protobufs by running the following from the root of this project:
          /// `PROTON_DRIVE_DDK_DIR={path/to/where/you/have/checked/out/desktop-dev-kit} bash PDDesktopDevKit/update_files_from_ddk.sh`
          url: "https://github.com/ProtonDriveApps/sdk-tech-demo/releases/download/0.2.10/ProtonDriveDDK.xcframework.zip",
          checksum: "760c5a8516bed87bb5f3ff941837061cc90735d1c52e2ef17bfdf6998926878a"
        ),
    ]
)

extension Range where Bound == Version {
    static let suitable = Self(uncheckedBounds: ("0.0.0", "99.0.0"))
}
