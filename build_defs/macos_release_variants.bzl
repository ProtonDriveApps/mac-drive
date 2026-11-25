"""Native optimized macOS QA/Store products, matching shared Xcode configs."""
load("@rules_apple//apple:macos.bzl", "macos_application", "macos_extension")
load("@rules_swift//swift:swift.bzl", "swift_library")
load(":plist_template.bzl", "plist_template")

def macos_store_product(app_sources, extension_sources):
    variant = "Store"
    host = "drive-api.proton.me"
    identifier = ""
    icon = "AppIcon-Release-External"
    flags = ["PRODUCTION_LEVEL_LOGS"]
    defines = ["SSL_PINNING", "HAS_BUILTIN_UPDATER"] + flags
    swift_library(
        name = "ProtonDriveMac" + variant + "Sources",
        tags = ["manual"],
        module_name = "ProtonDriveMac",
        features = ["swift.add_target_name_to_output"],
        srcs = app_sources,
        # Compile the startup storyboard with the Swift module's identity;
        # bundle-owned resources otherwise use ProtonDriveMacQA/Store.
        data = native.glob(["ProtonDriveMac/Base.lproj/*.storyboard"]),
        defines = defines,
        deps = [
            "//PDClient", "//PDCore", "//PDFileProvider", "//PDLocalization",
            "//PDLogin-macOS", "//PDUIComponents", "//PMEventsManager",
            "@swiftpkg_sparkle//:Sparkle",
            "@swiftpkg_protoncore_ios//:ProtonCoreCryptoDrivePatchedGoImplementation",
        ],
    )
    swift_library(
        name = "ProtonDriveFileProviderMac" + variant + "Sources",
        tags = ["manual"],
        module_name = "ProtonDriveFileProviderMac",
        features = ["swift.add_target_name_to_output"],
        srcs = extension_sources,
        defines = defines,
        deps = ["//PDFileProvider", "//PDCore", "//PDFileProviderOperations",
                "@swiftpkg_protoncore_ios//:ProtonCoreCryptoDrivePatchedGoImplementation"],
    )
    for component, plist, bundle_id, executable in [
        ("App", "ProtonDriveMac/Info.plist", "ch.protonmail.drive", "Proton Drive"),
        ("Extension", "ProtonDriveFileProviderMac/Info.plist", "ch.protonmail.drive.fileprovider", "ProtonDriveFileProviderMac"),
    ]:
        substitutions = {
            "<string>Debug</string>": "<string>0</string>",
            "$(APP_VERSION_IDENTIFIER)": identifier,
            "$(DEVELOPMENT_LANGUAGE)": "en",
            "$(PRODUCT_MODULE_NAME)": "ProtonDriveMac" if component == "App" else "ProtonDriveFileProviderMac",
            "$(EXECUTABLE_NAME)": executable,
            "$(PRODUCT_BUNDLE_IDENTIFIER)": bundle_id,
            "$(PRODUCT_NAME)": executable,
            "$(DEFAULT_API_HOST)": host,
            "$(MACOSX_DEPLOYMENT_TARGET)": "13.0",
        }
        if component == "App":
            substitutions["\t<key>CFBundleIconFile</key>\n\t<string></string>"] = ""
        else:
            substitutions["$(PRODUCT_BUNDLE_PACKAGE_TYPE)"] = "XPC!"
        plist_template(name = variant + component + "Info", src = plist, substitutions = substitutions, version_file = "//:VERSION", tags = ["manual"])
    macos_extension(
        name = "ProtonDriveFileProviderMac" + variant,
        tags = ["manual"],
        bundle_name = "ProtonDriveFileProviderMac",
        bundle_id = "ch.protonmail.drive.fileprovider",
        minimum_os_version = "13.0",
        infoplists = [":" + variant + "ExtensionInfo"],
        entitlements = "ProtonDriveFileProviderMac/ProtonDriveFileProvider.entitlements",
        codesignopts = ["--options=runtime"],
        resources = native.glob([
            "ProtonDriveSharedMac/Metrics/DB/Metrics.xcdatamodeld/**",
            "ProtonDriveMac/Assets.xcassets/**",
        ], exclude = ["ProtonDriveMac/Assets.xcassets/*.appiconset/**"]),
        deps = [":ProtonDriveFileProviderMac" + variant + "Sources", ":SDKSystemLibraries"],
    )
    macos_application(
        name = "ProtonDriveMac" + variant,
        tags = ["manual"],
        bundle_name = "Proton Drive",
        bundle_id = "ch.protonmail.drive",
        minimum_os_version = "13.0",
        infoplists = [":" + variant + "AppInfo"],
        entitlements = "ProtonDriveMac/ProtonDrive.entitlements",
        codesignopts = ["--options=runtime"],
        extensions = [":ProtonDriveFileProviderMac" + variant],
        additional_contents = {
            ":ProtonDriveMacLauncher": "Library/LoginItems",
            ":ch.protonmail.drive.agent": "Library/LaunchAgents",
        },
        app_icons = native.glob(["ProtonDriveMac/Assets.xcassets/" + icon + ".appiconset/**"]),
        resources = native.glob([
            "ProtonDriveMac/Assets.xcassets/**",
            "ProtonDriveSharedMac/Metrics/DB/Metrics.xcdatamodeld/**",
        ], exclude = ["ProtonDriveMac/Assets.xcassets/*.appiconset/**"]) + ["ReleaseNotes.html"],
        deps = [":ProtonDriveMac" + variant + "Sources", ":ProtonDriveMacEntryPoint"],
    )
