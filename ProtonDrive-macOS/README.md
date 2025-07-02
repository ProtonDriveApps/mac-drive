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

## Troubleshooting

### General environment cleanup
For the vast majority of scenarios, you can resolve environmental problems by clearing `Derived Data` and running our cleanup script (WARNING: this also clears any files/folders in the Proton Drive folders):
`bash Scripts/macos/uninstall.sh`

### Finder freezing or expected file icons/options not displayed
Sometimes the Finder itself runs into issues (typically identified by unexpected UI states in Finder). To fix, run:
`bash Scripts/macos/restart_finder.sh`

### FileProvider not initiating/running
You likely have existing Proton Drive FileProvider instances interfering with the one you wish to run if you see any errors similar to:
`The operation couldn't be completed. (NSFileProviderErrorDomain error -2001.)` (error codes -2002, -2013 & -2014 are other error codes that could indicate a similar issue with running the FileProvider)

You can confirm this by running `pluginkit -mADvvvvi ch.protonmail.drive.fileprovider`

If this returns one or more instance of the Proton Drive FileProvider, then you should remove them before rerunning the app:
`bash Scripts/macos/unregister.sh`

If `pluginkit` doesn't return anything or unregistering didn't resolve the issue, you should check if a rogue FileProvider is still registered with the `fileproviderctl` process:
`fileproviderctl dump ch.protonmail.drive`

If this returns something, then you should look for the `bundle URL`(s), decifer the location from this obfuscated format and permanently delete it (make sure it isn't in trash).

## Contributions

Contributions are not accepted at the moment.

## Dependencies

All dependencies are managed by SPM.

## License

The code and data files in this distribution are licensed under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See <https://www.gnu.org/licenses/> for a copy of this license.

See [LICENSE](LICENSE) file

Copyright (c) 2024 Proton AG
