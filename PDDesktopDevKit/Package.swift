// swift-tools-version: 5.9.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let PATH_TO_DDK_DIRECTORY = ""

let package = Package(
    name: "PDDesktopDevKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "PDDesktopDevKit",
            type: .static,
            targets: ["PDDesktopDevKit"]),
    ],
    dependencies: [
        // dependency on ProtonCore is needed to get the go-crypto
        // that must be linked together with dotNET DDK static framework
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "33.2.0"),

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
        .package(url: "https://gitlab.protontech.ch/drive/sdk-swift.git", branch: "0.0.16-ddk"),

        /// To use a local build of the DDK during development:
        /// 1. In the DDK repo run `./scripts/build_framework.sh`
        /// 2. Fill in `PATH_TO_DDK_DIRECTORY` in the top of the file and use the line below instead of the one above
//        .package(name: "ProtonDriveDDK", path: PATH_TO_DDK_DIRECTORY),

        // Only for tests
        .package(name: "PDClient", path: "../PDClient"),
    ],
    targets: [
        .target(
            name: "PDDesktopDevKit",
            dependencies: [
                // two products from the local build of the DDK during development
//                .product(name: "ProtonDriveDDK", package: "ProtonDriveDDK"),
//                .product(name: "ProtonDriveProtos", package: "ProtonDriveDDK"),

                // two products from the remote sdk-swift SPM package
                .product(name: "ProtonDriveDDK", package: "sdk-swift"),
                .product(name: "ProtonDriveProtos", package: "sdk-swift"),

                // the multiversion build is a special crypto build that contains both the v2 and v3 API
                // v2 API is used on the Swift side, v3 API is used on the dotNET side
                // by having both API, we can link the same crypto library in two places
                .product(name: "GoLibsCryptoMultiversionPatchedGo", package: "protoncore_ios"),
            ],
            // these parameters will be passed to the linking step of the final binary.
            // so it's the extension when building the app, test runner when running tests etc.
            linkerSettings: [
                // These frameworks are required by dotNET runtime
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("GSS"),
                .unsafeFlags([
                    // the 3 paths below point to the place where bootstrapper is available
                    // bootstrapper must be linked to the final binary

                    // path used for the local build of the DDK during development
//                    "-L\(PATH_TO_DDK_DIRECTORY)/Resources",
                    // path used in normal builds
                    "-L${BUILD_DIR}/../../SourcePackages/checkouts/sdk-swift/Resources",
                    // path used in archive builds
                    "-L${BUILD_DIR}/../../../../../SourcePackages/checkouts/sdk-swift/Resources",

                    // the bootstrapper contains the code to start the dotNET runtime – it asks the system API
                    // to spawn a new thread for garbage collector, allocate the memory to be managed by dotNET etc.
                    "-llibbootstrapperdll.osx-arm64.o",
                    "-llibbootstrapperdll.osx-x64.o",
                ]),
            ]
        ),
    ]
)
