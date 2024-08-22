# Proton Drive for macOS

macOS client for end-to-end encrypted cloud storage made by Proton AG. Securely backup and share your files.

## Targets

ProtonDrive for macOS has two important schemas used regularly during development:
- `ProtonDrive-macOS` - runs the menu bar app
- `ProtonDriveFileProvider-macOS` - runs the File Provider, which handles all the file-sync related operations

## Setup

1. Have macOS up to date and install Xcode
2. Open `ProtonDrive.xcworkspace`
3. Check the development provisioning profiles of the `ProtonDriveMac-Sparkle` target, adding your certificate and device to the existing provisioning profile or creating your own
4. Check the development provisioning profiles of the `ProtonDriveFileProviderMac` target, adding your certificate and device to the existing provisioning profile or creating your own
5. Check the development provisioning profiles of the `ProtonDriveMacLauncher` target, adding your certificate and device to the existing provisioning profile or creating your own

## Debugging

Debugging the `ProtonDrive-macOS` target is straight forward, but to debug the `ProtonDriveFileProvider-macOS` extension, you will need to try the following two approaches and use whichever works on your setup:
In both cases, start by first running `ProtonDrive-macOS`.
1. Run `ProtonDriveFileProvider-macOS` and hope it automatically attaches to the running "Proton Drive" process
2. Attach to `ProtonDriveFileProvider-macOS` by choosing `Debug -> Attach to Process -> ProtonDriveFileProviderMac` from the Xcode menu
If you don't get any debug output for the File Provider, you may have to use the `Console` app.

## Contributions

Contributions are not accepted at the moment.

## Dependencies

This app uses CocoaPods for most dependencies. Everything is inside this repository, so no need to run `pod install`.

## License

The code and data files in this distribution are licensed under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See <https://www.gnu.org/licenses/> for a copy of this license.

See [LICENSE](LICENSE) file

Copyright (c) 2023 Proton AG
