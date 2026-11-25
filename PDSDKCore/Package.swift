// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription
import Foundation

let SDK_PACKAGE: PackageDescription.Package.Dependency = if let localSDKPath = Config().localSDKPath {
    .package(name: "ProtonDriveSDK", path: localSDKPath)
} else {
    /// To update the SDK dependency:
    /// 1. Choose a published release branch in the SDK repository listed below.
    /// 2. Update the branch here and in `third_party/Package.swift`.
    /// 3. From the repository root, run `swift package --package-path third_party resolve`
    ///    to refresh the lockfile, then rebuild the app.
    .package(name: "ProtonDriveSDK",
             url: "https://github.com/ProtonDriveApps/sdk-swift.git",
             branch: "0.32.1-rust")
}

let package = Package(
    name: "PDSDKCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PDSDKCore", targets: ["PDSDKCore"]),
    ],
    dependencies: [
        .package(name: "PDCore", path: "../PDCore"),
        .package(name: "PDLocalization", path: "../PDLocalization"),
        SDK_PACKAGE,
        .package(url: "https://github.com/AliSoftware/OHHTTPStubs", exact: "9.1.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0") // Same setting from ProtonCore
    ],
    targets: [
        .target(
            name: "PDSDKCore",
            dependencies: [
                .product(name: "ProtonDriveSDK", package: "ProtonDriveSDK"),
                .product(name: "PDCore", package: "PDCore"),
                .product(name: "PDLocalization", package: "PDLocalization"),
            ],
            path: "PDSDKCore"
        ),
    ]
)

/// To use a local SDK repo, create a file named "config.json" in this directory, with the following schema:
/// `{ "localSDKPath": String }`
/// NOTE: after changing the `config.json` file, delete Package.resolved and re-run package version resolution.
struct Config: Decodable {
    let localSDKPath: String?

    init() {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(components: "config.json")
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(Config.self, from: data),
           let localSDKPath = config.localSDKPath,
           !localSDKPath.isEmpty {
            self.localSDKPath = localSDKPath
        } else {
            self.localSDKPath = nil
        }
    }
}
