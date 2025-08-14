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
        .package(name: "PDClient", path: "../PDClient"),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "32.7.1"),

        /// Updating the DDK:
        /// Step 1 - Release a new version
        /// a. Navigate to https://gitlab.protontech.ch/drive/desktop-dev-kit/-/pipelines/new
        /// b. (Optional) Choose a branch
        /// c. Add a `DDK_VERSION` variable with a SemVer value
        /// d. Click "New pipeline"
        /// e. Navigate to the new pipeline
        /// f. Manually trigger the "build:test" job
        /// g. Wait for the pipeline to complete
        /// Step 2 - Use the new version
        /// a. Update the version number below
        /// b. Rebuild the app
        .package(url: "https://gitlab.protontech.ch/drive/sdk-swift.git", branch: "0.0.12-ddk"),

            /// To use a local build of the DDK during development:
            /// 1. In the DDK repo run `./scripts/build_framework.sh`
            /// 2. Replace `PATH_TO_DDK_DIRECTORY` in the line below and use that line instead of the one above
    //        .package(name: "ProtonDriveDDK", path: "{PATH_TO_DDK_DIRECTORY}/build/ProtonDriveDDKSPM"),
        ],
    targets: [
        .target(
            name: "PDDesktopDevKit",
            dependencies: [
                //                .product(name: "ProtonDriveDDK", package: "ProtonDriveDDK"),
                //                .product(name: "ProtonDriveProtos", package: "ProtonDriveDDK"),
                                .product(name: "ProtonDriveDDK", package: "sdk-swift"),
                                .product(name: "ProtonDriveProtos", package: "sdk-swift")
            ]),
    ]
)
