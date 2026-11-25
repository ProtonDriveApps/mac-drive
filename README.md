# Proton Drive for macOS

This source snapshot contains the production macOS application and its local Swift
packages. Test suites, internal automation and instrumentation, and development signing are excluded. `export-manifest.json` records the source commit,
release version, file hashes, executable modes, and symlink targets.

## Build

Install Xcode 27.2 and select it with `xcode-select`, or set `DEVELOPER_DIR` to its
`Contents/Developer` directory. Accept the Xcode license and install its additional
components before building. No company provisioning certificate is required to
compile the public source.

```sh
./tools/bootstrap-bazel
./tools/bazel build //ProtonDrive-macOS:ProtonDriveMacStore
```

The default build produces an optimized universal ARM64/Intel application with
ad-hoc signing. It preserves the production bundle identifiers, entitlements,
resources, API endpoint, and VERSION-driven metadata. Ad-hoc signing permits
build inspection; it does not provide Apple's authorization to run restricted
entitlements, install File Provider extensions, or distribute a trusted release.

External dependencies are pinned in `third_party/Package.resolved` and
`MODULE.bazel`. The build has no company remote-cache configuration. Swift
package manifests are retained with internal test dependencies removed; Bazel is
the supported application build entry point.

See [LICENSE](LICENSE) for license terms.
